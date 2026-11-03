"""Stack adapters: one interface per language. Rust, Python (stdlib ast, tokenize) and TypeScript/JavaScript (lexical masking, stdlib only).

Adapter interface:
  classify(path, test_globs) -> "test" | "prod" | None (None: not a source file of this stack)
  test_fns(text) -> [TestFn(name, line, markers)]   markers: "ignore" (skip-like), "should_panic";
      name: fn name qualified by its enclosing mods (`m1::works`); top-level fns are bare
  assertions(text) -> [Assertion(line, fn, scope, kind, left, right, text)]  fn: enclosing test fn name or None;
      scope: inside a test fn or a #[cfg(test)] mod (production code is never in scope);
      kind: eq | ne | other (assert!(a == b) is eq); left/right: whitespace-normalized operands (eq/ne only);
      text: the whole assert call, whitespace-normalized (for messages)
  test_bodies(text) -> {name: (line, body)}   body: whitespace-normalized source of a #[test] fn item (R1/R4 compare)
  default_test_cmd: the toolchain command a runner starts from (rust: cargo test)
  test_cmd_in(crate) -> the test command for a checkout (ts: vitest or jest from package.json); default: default_test_cmd
  worktree_setup(repo, wt, project_dir): per-worktree toolchain setup (ts links the caller's node_modules); default no-op
  ignored_text(name) -> R2 problem for a test marked ignored (ts: skipped)
  test_argv(cmd, path, name) -> argv that runs one named test (path: the file the test is in)
  outcome(rc, output) -> verdict of one run:
      pass | fail | build | none | error | timeout | env (rc None: executable missing, toolchain absent)
  suppressions(text) -> [Suppression(line, end_line, kind, lints, lint_text, reason)]
  suppression_text(sup) -> (problem, hint) of a suppression without a reason
  parse_error(text) -> None | (line, message): the file does not parse; the checks cannot read it
  mutation_skips(text) -> [(line, end_line, marker)]: markers that hide code from the R3 tool (rust #[mutants::skip],
      python `# pragma: no mutate`, ts `// Stryker disable`), in code, not strings; default none
  mutation_config(path, load) -> None | what: this change edits the R3 tool's config (cargo-mutants mutants.toml,
      [tool.mutmut], stryker config). load() -> (base text or None, head text or None), read only when needed
"""
import configparser
import ast
import functools
import io
import json
import os
import re
import shlex
import tokenize
from collections import namedtuple

from .globs import any_glob

TestFn = namedtuple("TestFn", "name line markers")
Assertion = namedtuple("Assertion", "line fn scope kind left right text owner")
Item = namedtuple("Item", "qname line is_test markers body span")
CFG_TEST = re.compile(r"#\[\s*cfg\s*\(\s*test\s*\)\s*\]")
BODY_END = re.compile(r"[{;]")
ATTR = re.compile(r"#\[[^\]]*\]")
Suppression = namedtuple("Suppression", "line end_line kind lints lint_text reason")

RESULT = re.compile(r"test result: \w+\. (\d+) passed; (\d+) failed")
BUILD = re.compile(r"could not compile|error\[E\d{4}\]")
RAW = re.compile(r'(?:br|cr|r)(#*)"')
FN = re.compile(r'((?:#\[[^\]]*\]\s*)*)(?:pub(?:\s*\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?fn\s+(\w+)')
ATTR_START = re.compile(r"#!?\[")
ASSERT = re.compile(r"\b(\w*assert\w*)!\s*[(\[{]")
SHOULD_PANIC = re.compile(r"#\[\s*should_panic\b")
MOD = re.compile(r"((?:#\[[^\]]*\]\s*)*)(?:pub(?:\s*\([^)]*\))?\s+)?mod\s+(\w+)\s*\{")
MODULE = re.compile(r"#\[\s*cfg\s*\(\s*test\s*\)\s*\]\s*(?:#\[[^\]]*\]\s*)*(?:pub(?:\s*\([^)]*\))?\s+)?mod\s+\w+\s*\{")
TEST_ATTR = re.compile(r"#\[\s*(?:\w+::)*(?:test|rstest|test_case)\b")
IGNORE_ATTR = re.compile(r"#\[\s*(?:ignore\b|cfg_attr\s*\(.*\bignore\b|cfg\s*\(\s*(?:any\s*\(\s*\)|FALSE|false|not\s*\(\s*test\s*\))\s*\)\s*\])")
OPEN, CLOSE = "([{", ")]}"


def _ident(ch):
    return ch.isalnum() or ch == "_"


def mask(text):
    """blank comments (nested block comments too) and literal contents; newlines and length kept.
    Strings may span lines. Char literals are told apart from lifetimes by the closing quote."""
    out = list(text)
    n = len(text)

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    i = 0
    while i < n:
        c = text[i]
        if c == "/" and text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif c == "/" and text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif c in "rbc" and (i == 0 or not _ident(text[i - 1])) and RAW.match(text, i):
            m = RAW.match(text, i)
            close = '"' + m.group(1)
            j = text.find(close, m.end())
            j = n if j < 0 else j + len(close)
            blank(i, j)
            i = j
        elif c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n)
            blank(i, j)
            i = j
        elif c == "'":
            if text.startswith("\\", i + 1):
                j = text.find("'", i + 3)
                j = n if j < 0 else j + 1
                blank(i, j)
                i = j
            elif i + 2 < n and text[i + 2] == "'":
                blank(i, i + 3)
                i += 3
            else:
                i += 1  # lifetime or label
        else:
            i += 1
    return "".join(out)


def norm(s):
    return None if s is None else re.sub(r"\s+", "", s)


def top_cmp(raw):
    """(kind, left, right) for a top-level == or != in raw, else None."""
    m = mask(raw)
    depth = 0
    for j in range(len(m) - 1):
        c = m[j]
        if c in OPEN:
            depth += 1
        elif c in CLOSE:
            depth -= 1
        elif depth == 0 and m[j:j + 2] in ("==", "!="):
            return ("eq" if m[j:j + 2] == "==" else "ne"), raw[:j], raw[j + 2:]
    return None


def close_of(m, i):
    """index of the bracket closing m[i] (masked text), or len(m)-1."""
    depth = 0
    for j in range(i, len(m)):
        if m[j] in OPEN:
            depth += 1
        elif m[j] in CLOSE:
            depth -= 1
            if depth == 0:
                return j
    return len(m) - 1


def args_of(text, m, i):
    """top-level comma-separated args of the call whose '(' is m[i]; text supplies the original spelling."""
    end = close_of(m, i)
    args, depth, start = [], 0, i + 1
    for j in range(i + 1, end):
        if m[j] in OPEN:
            depth += 1
        elif m[j] in CLOSE:
            depth -= 1
        elif m[j] == "," and depth == 0:
            args.append(text[start:j].strip())
            start = j + 1
    last = text[start:end].strip()
    if last:
        args.append(last)
    return args


class Adapter:
    name = ""
    default_test_cmd = ""
    manifests = ()  # files that make a directory a project of this stack (a missing one is named by a hint)

    def classify(self, path, test_globs):
        raise NotImplementedError

    def test_fns(self, text):
        raise NotImplementedError

    def assertions(self, text):
        raise NotImplementedError

    def suppressions(self, text):
        raise NotImplementedError

    def mutation_skips(self, text):
        return []

    def mutation_config(self, path, load):
        return None

    def calls(self, text):
        raise NotImplementedError

    def test_bodies(self, text):
        raise NotImplementedError

    def test_argv(self, cmd, path, name):
        raise NotImplementedError

    def outcome(self, rc, out):
        raise NotImplementedError

    def test_cmd_in(self, crate):
        """the test command for a checkout whose crate dir is `crate` (absolute): --test-cmd overrides it."""
        return self.default_test_cmd

    def worktree_setup(self, repo, wt, project_dir):
        """called once a worktree of the repo exists: whatever the toolchain needs beside the checkout (no-op by default)."""

    def parse_error(self, text):
        return None

    def suppression_text(self, sup):
        return f"`{sup.lint_text}` added without a reason", "fix the lint, or give the suppression a reason"

    def ignored_text(self, name):
        """R2 problem for a test marked ignored (skipped at run time)."""
        return f"test `{name}` marked #[ignore]"


def _innermost(spans, pos):
    """name of the innermost (name, open, close) span containing pos, or None."""
    hits = [s for s in spans if s[1] <= pos < s[2]]
    return max(hits, key=lambda s: s[1])[0] if hits else None


class RustAdapter(Adapter):
    name = "rust"
    default_test_cmd = "cargo test"
    manifests = ("Cargo.toml",)

    def classify(self, path, test_globs):
        if not path.endswith(".rs"):
            return None
        return "test" if any_glob(path, test_globs) else "prod"

    @staticmethod
    def _body(m, pos):
        """(open, close) of the fn body whose signature starts at pos, or None (declaration only)."""
        p = m.find("(", pos)
        if p < 0:
            return None
        mm = BODY_END.search(m, close_of(m, p) + 1)
        if not mm or mm.group() == ";":
            return None
        return (mm.start(), close_of(m, mm.start()))

    def _items(self, text):
        """(masked text, mods, fn items). mods: (attrs, open, close, name). Names are qualified by enclosing mods."""
        m = mask(text)
        mods = [(mo.group(1), mo.end() - 1, close_of(m, mo.end() - 1), mo.group(2)) for mo in MOD.finditer(m)]
        items = []
        for f in FN.finditer(m):
            attrs = ATTR.findall(f.group(1))
            inside = [(grp, name) for grp, b, e, name in mods if b < f.start() < e]
            # a test inside a mod disabled by cfg (cfg(any()), cfg(FALSE), cfg(not(test))) is disabled too
            mod_attrs = [a for grp, _ in inside for a in ATTR.findall(grp)]
            markers = ["ignore"] if any(IGNORE_ATTR.match(a) for a in attrs + mod_attrs) else []
            if any(SHOULD_PANIC.match(a) for a in attrs):
                markers.append("should_panic")
            qname = "::".join([name for _, name in inside] + [f.group(2)])
            body = self._body(m, f.end())
            span = (f.start(), body[1] + 1 if body else f.end())
            items.append(Item(qname, m.count("\n", 0, f.start(2)) + 1, any(TEST_ATTR.match(a) for a in attrs),
                              markers, body, span))
        return m, mods, items

    def test_fns(self, text):
        return [TestFn(it.qname, it.line, it.markers) for it in self._items(text)[2] if it.is_test]

    def assertions(self, text):
        m, mods, items = self._items(text)
        tests = [(it.qname, *it.body) for it in items if it.is_test and it.body]
        owners = [(it.qname, *it.body) for it in items if it.body]
        scoped = tests + [(None, o, c) for attrs, o, c, _ in mods if any(CFG_TEST.match(a) for a in ATTR.findall(attrs))]
        out = []
        for a in ASSERT.finditer(m):
            pos = a.start()
            base = re.sub(r"^debug_", "", a.group(1))
            kind = "eq" if base.endswith("_eq") else "ne" if base.endswith("_ne") else "other"
            left = right = None
            if m[a.end() - 1] == "(":
                args = args_of(text, m, a.end() - 1)
                if kind in ("eq", "ne") and len(args) >= 2:
                    left, right = args[0], args[1]
                elif base in ("assert", "prop_assert") and args:
                    cmp = top_cmp(args[0])
                    if cmp:
                        kind, left, right = cmp
            call = " ".join(text[pos:close_of(m, a.end() - 1) + 1].split())
            out.append(Assertion(m.count("\n", 0, pos) + 1, _innermost(tests, pos), any(b <= pos < e for _, b, e in scoped),
                                 kind, norm(left), norm(right), call, _innermost(owners, pos)))
        return out

    def test_bodies(self, text):
        """{qname: (line, body)} for each #[test] fn. body: whitespace-normalized item text, attributes and signature included."""
        _, _, items = self._items(text)
        return {it.qname: (it.line, norm(text[it.span[0]:it.span[1]])) for it in items if it.is_test}

    def test_argv(self, cmd, path, name):
        """one named test: libtest --exact matches the full mod-qualified name, so one test per run."""
        return shlex.split(cmd) + ["--", "--exact", name]

    def outcome(self, rc, out):
        """verdict of one test run from its exit code and output (cargo test / libtest shapes)."""
        if rc is None:
            return "env"
        if rc == "timeout":
            return "timeout"
        if BUILD.search(out):
            return "build"
        res = RESULT.findall(out)
        if not res:
            return "error"  # cargo failed before any test result (no manifest, bad flags)
        passed = sum(int(p) for p, _ in res)
        failed = sum(int(f) for _, f in res)
        if failed or rc != 0:
            return "fail"
        return "pass" if passed else "none"

    def calls(self, text):
        """{fn qname: bare names it calls as plain or path calls (f(), self::f(), super::f()); method calls (x.f()) excluded}"""
        m, _, items = self._items(text)
        return {it.qname: set(re.findall(r"(?<![\w.])(?:\w+::)*(\w+)\s*\(", m[it.body[0]:it.body[1]])) for it in items if it.body}

    def suppressions(self, text):
        """lint-suppression attributes (allow/expect, also inside cfg_attr) found in code, not comments or strings.
        reason: non-empty `reason = "..."` inside the attribute, or a // comment after it on its last line."""
        m = mask(text)
        out = []
        for a in ATTR_START.finditer(m):
            br = a.end() - 1
            end = close_of(m, br)
            body = m[br + 1:end]
            mm = re.match(r"\s*(allow|expect)\s*\(", body)
            if not mm and re.match(r"\s*cfg_attr\s*\(", body):
                mm = re.search(r"\b(allow|expect)\s*\(", body)
            if not mm:
                continue
            lint_open = br + 1 + mm.end() - 1
            raw = text[lint_open + 1:close_of(m, lint_open)]
            eol = text.find("\n", end)
            tail = text[end + 1:len(text) if eol < 0 else eol]
            reason = bool(re.search(r'\breason\s*=\s*"[^"]*[^\s"][^"]*"', raw)) or bool(re.search(r"//\s*\S", tail))
            out.append(Suppression(m.count("\n", 0, a.start()) + 1, m.count("\n", 0, end) + 1, mm.group(1),
                                   norm(raw), " ".join(raw.split()), reason))
        return out

    def mutation_skips(self, text):
        """`#[mutants::skip]`, also inside cfg_attr, in code (masked: comments and strings do not count)."""
        m = mask(text)
        out = []
        for a in ATTR_START.finditer(m):
            br = a.end() - 1
            end = close_of(m, br)
            if re.search(r"\bmutants\s*::\s*skip\b", m[br + 1:end]):
                out.append((m.count("\n", 0, a.start()) + 1, m.count("\n", 0, end) + 1,
                            "#[" + " ".join(text[br + 1:end].split()) + "]"))
        return out

    def mutation_config(self, path, load):
        """cargo-mutants reads .cargo/mutants.toml (exclude_globs, exclude_re, test args): any change to one."""
        return "cargo-mutants config" if os.path.basename(path) == "mutants.toml" else None

    def suppression_text(self, sup):
        return (f"#[{sup.kind}({sup.lint_text})] added without a reason",
                'fix the lint, or give the suppression a reason: #[allow(lint, reason = "...")]')

PY_ASSERT_EQ = {"assertEqual", "assertEquals", "assertDictEqual", "assertListEqual", "assertTupleEqual",
                "assertSetEqual", "assertMultiLineEqual", "assertSequenceEqual"}
PY_ASSERT_NE = {"assertNotEqual", "assertNotEquals"}
PY_SKIP = {"skip", "skipIf", "skipUnless", "skipif", "xfail"}
PY_NOQA = re.compile(r"#\s*noqa\b(?::\s*([A-Za-z]+\d+(?:\s*,\s*[A-Za-z]+\d+)*))?", re.I)
PY_TYPE_IGNORE = re.compile(r"#\s*type:\s*ignore\b(?:\[([^\]]*)\])?")
PY_BUILD = re.compile(r"Failed to import test module|ERROR collecting|during collection|^ERROR \S+\.py\s*$", re.M)
PY_PASSED = re.compile(r"\b[1-9]\d* passed\b")
PY_OK = re.compile(r"^OK\b", re.M)
PY_RAN = re.compile(r"^Ran [1-9]\d* tests?\b", re.M)
PY_SEP = re.compile(r"^[\s#:;,\-\u2014\u2013]+")


def _last(node):
    """last name of a dotted expression (unittest.TestCase -> TestCase); None for anything else."""
    if isinstance(node, ast.Attribute):
        return node.attr
    if isinstance(node, ast.Name):
        return node.id
    return None


def _skip_decorated(decorators):
    return any(_last(d.func if isinstance(d, ast.Call) else d) in PY_SKIP for d in decorators)


def _body_skips(fn):
    """a test body that skips itself at run time: self.skipTest(), pytest.skip(), skip(), raise SkipTest."""
    for n in ast.walk(fn):
        if isinstance(n, ast.Call):
            f = n.func
            if isinstance(f, ast.Attribute) and (f.attr == "skipTest" or (f.attr == "skip" and _last(f.value) == "pytest")):
                return True
            if isinstance(f, ast.Name) and f.id == "skip":
                return True
        if isinstance(n, ast.Raise) and n.exc is not None:
            exc = n.exc.func if isinstance(n.exc, ast.Call) else n.exc
            if _last(exc) == "SkipTest":
                return True
    return False


def _ws(s):
    return re.sub(r"\s+", "", s)


class _Scan(ast.NodeVisitor):
    """One pass over a module: test fns (pytest functions, pytest `Test*` classes, unittest TestCase methods),
    assertions with their enclosing test fn, calls per function, test bodies. Scope entries: ("class", name,
    is_test, skipped, None) or ("fn", name, is_test, qname, None)."""

    def __init__(self):
        self.known = set()  # TestCase-derived class names seen so far (a subclass in the same file counts)
        self.scope = []
        self.tests = []
        self.bodies = {}
        self.asserts = []
        self.calls = {}

    def _chain(self):
        return [e[1] for e in self.scope]

    def _record(self, node, kind, left, right, text):
        test = next((e[3] for e in reversed(self.scope) if e[0] == "fn" and e[2]), None)
        fns = [e[3] for e in self.scope if e[0] == "fn"]
        owner = fns[-1] if fns else None
        scope = any((e[0] == "fn" and e[2]) or (e[0] == "class" and e[2]) for e in self.scope)
        self.asserts.append(Assertion(node.lineno, test, scope, kind, left, right, text, owner))

    def visit_ClassDef(self, node):
        tc = any(_last(b) == "TestCase" or _last(b) in self.known for b in node.bases)
        if tc:
            self.known.add(node.name)
        self.scope.append(("class", node.name, tc or node.name.startswith("Test"), _skip_decorated(node.decorator_list), None))
        for stmt in node.body:
            self.visit(stmt)
        self.scope.pop()

    def _func(self, node):
        qname = "::".join(self._chain() + [node.name])
        parent = self.scope[-1] if self.scope else None
        if parent is None:
            is_test = node.name.startswith("test")
        elif parent[0] == "class":
            is_test = node.name.startswith("test") and parent[2]
        else:
            is_test = False
        skipped = any(e[0] == "class" and e[3] for e in self.scope) or _skip_decorated(node.decorator_list)
        if is_test:
            markers = ["ignore"] if skipped or _body_skips(node) else []
            self.tests.append(TestFn(qname, node.lineno, markers))
            self.bodies[qname] = (node.lineno, _ws(ast.unparse(node)))
        self.scope.append(("fn", node.name, is_test, qname, None))
        for stmt in node.body:
            self.visit(stmt)
        self.scope.pop()

    visit_FunctionDef = _func
    visit_AsyncFunctionDef = _func

    def visit_Assert(self, node):
        t = node.test
        kind, left, right = "other", None, None
        if isinstance(t, ast.Compare) and len(t.ops) == 1 and isinstance(t.ops[0], (ast.Eq, ast.NotEq)):
            kind = "eq" if isinstance(t.ops[0], ast.Eq) else "ne"
            left, right = _ws(ast.unparse(t.left)), _ws(ast.unparse(t.comparators[0]))
        self._record(node, kind, left, right, " ".join(ast.unparse(node).split()))

    def visit_Call(self, node):
        f = node.func
        if isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name) and f.value.id == "self" and f.attr.startswith("assert"):
            kind, left, right = "other", None, None
            if f.attr in PY_ASSERT_EQ or f.attr in PY_ASSERT_NE:
                if len(node.args) >= 2:
                    kind = "eq" if f.attr in PY_ASSERT_EQ else "ne"
                    left, right = _ws(ast.unparse(node.args[0])), _ws(ast.unparse(node.args[1]))
            self._record(node, kind, left, right, " ".join(ast.unparse(node).split()))
        elif isinstance(f, ast.Attribute) and f.attr == "raises" and _last(f.value) == "pytest":
            self._record(node, "other", None, None, " ".join(ast.unparse(node).split()))
        fns = [e[3] for e in self.scope if e[0] == "fn"]
        name = f.id if isinstance(f, ast.Name) else f.attr if isinstance(f, ast.Attribute) and _last(f.value) in ("self", "cls") else None
        if fns and name:
            self.calls.setdefault(fns[-1], set()).add(name)
        self.generic_visit(node)


class PythonAdapter(Adapter):
    """Python: pytest functions and `Test*` classes, unittest TestCase methods (test_* / test* prefix, as both runners collect).
    Names: `test_fn`, `Class::test_method` (Class nested in another class: `Outer::Class::test_method`)."""
    name = "python"
    default_test_cmd = "python3 -m pytest"
    manifests = ("pyproject.toml", "setup.py", "setup.cfg")

    def classify(self, path, test_globs):
        if not path.endswith(".py"):
            return None
        return "test" if any_glob(path, test_globs) else "prod"

    @staticmethod
    def _scan(text):
        tree = ast.parse(text)
        sc = _Scan()
        sc.visit(tree)
        return sc

    def parse_error(self, text):
        try:
            ast.parse(text)
        except SyntaxError as e:
            return (e.lineno or 1, e.msg)
        except ValueError as e:
            return (1, str(e))
        return None

    def test_fns(self, text):
        return self._scan(text).tests

    def assertions(self, text):
        return self._scan(text).asserts

    def calls(self, text):
        return self._scan(text).calls

    def test_bodies(self, text):
        return self._scan(text).bodies

    def suppressions(self, text):
        """`# noqa` (codes optional) and `# type: ignore` (brackets optional) comments; reason: text after the codes."""
        out = []
        try:
            toks = list(tokenize.generate_tokens(io.StringIO(text).readline))
        except (tokenize.TokenError, SyntaxError):
            return out
        for tok in toks:
            if tok.type != tokenize.COMMENT:
                continue
            c = tok.string
            m = PY_NOQA.search(c)
            if m:
                codes = ",".join(x.strip() for x in m.group(1).split(",")) if m.group(1) else ""
                kind, lints = "noqa", "noqa" + (f" {codes}" if codes else "")
            else:
                m = PY_TYPE_IGNORE.search(c)
                if not m:
                    continue
                codes = _ws(m.group(1)) if m.group(1) else ""
                kind, lints = "type: ignore", "type: ignore" + (f"[{codes}]" if codes else "")
            reason = bool(PY_SEP.sub("", c[m.end():]).strip())
            out.append(Suppression(tok.start[0], tok.start[0], kind, lints, c.strip(), reason))
        return out

    def suppression_text(self, sup):
        return (f"`{sup.lint_text}` added without a reason",
                f"fix the lint, or give the suppression a reason after the codes: `{sup.lint_text} - why`")

    def mutation_skips(self, text):
        """`# pragma: no mutate` comments (mutmut skips the line)."""
        try:
            toks = list(tokenize.generate_tokens(io.StringIO(text).readline))
        except (tokenize.TokenError, SyntaxError):
            return []
        return [(t.start[0], t.start[0], t.string.strip()) for t in toks
                if t.type == tokenize.COMMENT and re.search(r"pragma\s*:\s*no\s+mutate\b", t.string)]

    def mutation_config(self, path, load):
        """mutmut reads [tool.mutmut] in pyproject.toml and [mutmut] in setup.cfg: a change to that table. Other edits to
        those files (version, dependencies) are not a mutation config change. A file that does not parse counts when
        either side mentions mutmut."""
        name = os.path.basename(path)
        if name not in ("pyproject.toml", "setup.cfg"):
            return None
        before, after = load()

        def table(text):
            if text is None:
                return None
            if name == "pyproject.toml":
                import tomllib
                return tomllib.loads(text).get("tool", {}).get("mutmut")
            cp = configparser.ConfigParser(interpolation=None)
            cp.read_string(text)
            return dict(cp["mutmut"]) if cp.has_section("mutmut") else None

        try:
            changed = table(before) != table(after)
        except Exception:
            changed = "mutmut" in (before or "") + (after or "")
        return ("[tool.mutmut]" if name == "pyproject.toml" else "[mutmut]") if changed else None

    def test_argv(self, cmd, path, name):
        """one named test. pytest: the nodeid (`path::Class::test`), which also runs unittest TestCase methods.
        A unittest command (`... unittest`): the dotted name (`tests.test_a.Class.test`)."""
        argv = shlex.split(cmd)
        if "unittest" in argv:
            return argv + [path[:-3].replace("/", ".") + "." + name.replace("::", ".")]
        return argv + ["-q", f"{path}::{name}"]

    def outcome(self, rc, out):
        """verdict of one run of pytest or unittest. Collection and import errors are build (like a compile error)."""
        if rc is None:
            return "env"
        if rc == "timeout":
            return "timeout"
        if re.search(r"No module named '?pytest", out):
            return "env"
        if PY_BUILD.search(out):
            return "build"
        if "_FailedTest" in out:
            return "error"  # unittest: the named test does not exist
        if "no tests ran" in out or re.search(r"^Ran 0 tests?\b", out, re.M) or rc == 5:
            return "none"
        if rc == 0:
            if PY_PASSED.search(out) or (PY_OK.search(out) and PY_RAN.search(out) and "skipped=" not in out):
                return "pass"
            if re.search(r"\b\d+ (skipped|xfailed|deselected)\b", out) or "skipped=" in out:
                return "none"
            return "error"  # exit 0 with no test result: the runner did not reach a test
        if rc == 1:
            return "fail"
        return "error"


# ---- TypeScript / JavaScript: lexical masking (no parser; stdlib only) ----
JS_EXT = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs")
JS_PAIR = {"(": ")", "[": "]", "{": "}"}
JS_REGEX_WORDS = {"return", "typeof", "case", "do", "else", "in", "of", "new", "delete", "void", "throw", "yield",
                  "await", "instanceof"}
JS_CALL = re.compile(r"(?<![\w$.])(describe|it|test|xit|xdescribe|xtest|fit|fdescribe|ftest)((?:\.\w+)*)\s*\(")
JS_FN = re.compile(r"(?<![\w$.])function\s*\*?\s*([A-Za-z_$][\w$]*)\s*\(")
JS_ARROW = re.compile(r"(?<![\w$.])(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=\n]+)?=\s*(async\s+)?")
JS_EXPECT = re.compile(r"(?<![\w$.])expect\s*\(")
JS_MEMBER = re.compile(r"\s*\.\s*(\w+)")
JS_CALLED = re.compile(r"(?<![\w$.])([A-Za-z_$][\w$]*)\s*\(")
JS_EQ = {"toBe", "toEqual", "toStrictEqual"}
JS_ESLINT = re.compile(r"^\s*(eslint-disable(?:-next-line|-line)?)(?![\w-])(.*)", re.S)
JS_TS_DIRECTIVE = re.compile(r"^\s*(@ts-(?:ignore|expect-error|nocheck))(?![\w-])(.*)", re.S)
JS_PLACEHOLDER = re.compile(r"%[sdifjoOp#%]|\$\w+")
JsCall = namedtuple("JsCall", "kind name start end skip only args")


def js_scan(text):
    """(masked, comments, errors). masked: same length and newlines, comments and literal contents blanked (strings,
    template literals, regex literals). comments: [(start, end, body)]. errors: [(pos, message)] for an unterminated
    block comment or template literal. A string that runs to a newline is not an error (JSX text has apostrophes);
    a regex literal is recognised only where an operand cannot be a division."""
    out = list(text)
    n = len(text)
    comments, errors = [], []

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    prev, word = "", ""  # last significant code char; last identifier when prev is one
    i = 0
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
            continue
        if c == "/" and text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            comments.append((i, j, text[i + 2:j]))
            blank(i, j)
            i = j
            continue
        if c == "/" and text.startswith("/*", i):
            j = text.find("*/", i + 2)
            if j < 0:
                errors.append((i, "unterminated block comment"))
                comments.append((i, n, text[i + 2:]))
                blank(i, n)
                i = n
            else:
                comments.append((i, j + 2, text[i + 2:j]))
                blank(i, j + 2)
                i = j + 2
            continue
        if c in "\"'":
            j = i + 1
            while j < n and text[j] not in (c, "\n"):
                j += 2 if text[j] == "\\" else 1
            j = min(j + 1, n) if j < n and text[j] == c else min(j, n)
            blank(i, j)
            i = j
            prev, word = "x", ""
            continue
        if c == "`":
            j, depth = i + 1, 0
            while j < n:
                ch = text[j]
                if ch == "\\":
                    j += 2
                    continue
                if depth == 0 and ch == "`":
                    break
                if depth == 0 and text.startswith("${", j):
                    depth, j = 1, j + 2
                    continue
                if depth and ch == "}":
                    depth = 0
                j += 1
            if j >= n:
                errors.append((i, "unterminated template literal"))
                j = n
            else:
                j += 1
            blank(i, j)
            i = j
            prev, word = "x", ""
            continue
        if c == "/" and (prev == "" or prev in "(,=:[!&|?{};+-*%<>~^" or (word and word in JS_REGEX_WORDS)):
            j, in_class = i + 1, False
            while j < n and text[j] != "\n":
                ch = text[j]
                if ch == "\\":
                    j += 2
                    continue
                if ch == "[":
                    in_class = True
                elif ch == "]":
                    in_class = False
                elif ch == "/" and not in_class:
                    break
                j += 1
            if j < n and text[j] == "/":
                j += 1
                while j < n and (text[j].isalnum() or text[j] == "_"):
                    j += 1
                blank(i, j)
                i = j
                prev, word = "x", ""
                continue
        if _ident(c) or c == "$":
            j = i
            while j < n and (_ident(text[j]) or text[j] == "$"):
                j += 1
            word, prev = text[i:j], text[j - 1]
            i = j
            continue
        prev, word = c, ""
        i += 1
    return "".join(out), comments, errors


def _js_name(raw):
    """a test name from its first argument: a string literal's value, else the argument's text."""
    r = raw.strip()
    if len(r) >= 2 and r[0] == r[-1] and r[0] in "'\"`":
        return re.sub(r"\\(.)", r"\1", r[1:-1])
    return " ".join(r.split())


def _close_then(m, i):
    """index after the close of the bracket group at m[i] (masked)."""
    return close_of(m, i) + 1


def _body_after(m, j):
    """(start, end) of a function body starting at the first non-space index j: a `{ ... }` block, or an arrow
    expression that runs to `;` or a newline at depth 0."""
    while j < len(m) and m[j].isspace():
        j += 1
    if j < len(m) and m[j] == "{":
        return j, close_of(m, j) + 1
    depth, k = 0, j
    while k < len(m):
        ch = m[k]
        if ch in OPEN:
            depth += 1
        elif ch in CLOSE:
            if depth == 0:
                break
            depth -= 1
        elif depth == 0 and (ch == ";" or ch == "\n"):
            break
        k += 1
    return j, k


def _functions(m):
    """[(name, start, end)] of named function declarations, `const f = ...` functions and arrows in masked text m."""
    out = []
    for f in JS_FN.finditer(m):
        p = m.find("(", f.end() - 1)
        if p < 0:
            continue
        b = m.find("{", _close_then(m, p))
        if b >= 0:
            out.append((f.group(1), f.start(), close_of(m, b) + 1))
    for f in JS_ARROW.finditer(m):
        j = f.end()
        if j < len(m) and m[j] == "(":
            k = _close_then(m, j)
            while k < len(m) and m[k].isspace():
                k += 1
            if not m.startswith("=>", k):
                continue
            s, e = _body_after(m, k + 2)
        elif m.startswith("function", j):
            p = m.find("(", j)
            if p < 0:
                continue
            b = m.find("{", _close_then(m, p))
            if b < 0:
                continue
            s, e = b, close_of(m, b) + 1
        else:
            k = re.match(r"[A-Za-z_$][\w$]*\s*=>", m[j:])
            if not k:
                continue
            s, e = _body_after(m, j + k.end())
        out.append((f.group(1), f.start(), e))
    return out


def _calls(text, m):
    """[JsCall] for describe/it/test and their modifiers, in source order. A call with no function argument is a
    todo (skip). `.each(table)(name, fn)` is one call whose span is the second call."""
    out = []
    for c in JS_CALL.finditer(m):
        ident, mods = c.group(1), [x for x in c.group(2).split(".") if x]
        prefix = m[max(0, c.start() - 12):c.start()]
        if re.search(r"\bfunction\s*\*?\s*$", prefix):
            continue
        open_ = c.end() - 1
        if "each" in mods:
            mm = re.compile(r"\s*\(").match(m, _close_then(m, open_))
            if not mm:
                continue
            open_ = mm.end() - 1
        args = args_of(text, m, open_)
        is_describe = "describe" in ident
        skip = ident in ("xit", "xdescribe", "xtest") or "skip" in mods or "todo" in mods or (not is_describe and len(args) < 2)
        only = ident in ("fit", "fdescribe", "ftest") or "only" in mods
        name = _js_name(args[0]) if args else ""
        out.append(JsCall("describe" if is_describe else "test", name, c.start(), close_of(m, open_) + 1, skip, only, args))
    return out


def _tests_with_scope(calls):
    """[(qualified name, JsCall, markers)]: a test's name joined with its enclosing describes by ' > '."""
    describes = [c for c in calls if c.kind == "describe"]
    out = []
    for t in (c for c in calls if c.kind == "test"):
        encl = sorted((d for d in describes if d.start < t.start and t.end <= d.end), key=lambda d: d.start)
        name = " > ".join([d.name for d in encl] + [t.name])
        markers = []
        if t.skip or any(d.skip for d in encl):
            markers.append("ignore")
        if t.only or any(d.only for d in encl):
            markers.append("only")
        out.append((name, t, markers))
    return out


@functools.lru_cache(maxsize=64)
def _ts_parse(text):
    """Everything the TS adapter reads from one file, parsed once: masked text, calls, tests, functions, comments."""
    m, comments, errors = js_scan(text)
    calls = _calls(text, m)
    tests = _tests_with_scope(calls)
    fns = _functions(m)
    return m, comments, errors, calls, tests, fns


def _line(text, pos):
    return text.count("\n", 0, pos) + 1


TS_BUILD = re.compile(r"Transform failed|Failed to load url|Failed to resolve import|Cannot find module|Cannot find package"
                      r"|Test suite failed to run|SyntaxError|\bTS\d{4}\b|Failed Suites")
TS_TESTS = re.compile(r"^\s*Tests\b:?(.*)$", re.M)
TS_RESULT = re.compile(r"(\d+) (passed|failed)\b")
TS_RE_SPECIAL = re.compile(r"([\\^$.|?*+()\[\]{}/])")


def _ts_counts(out):
    """(passed, failed) from the last `Tests` summary line of a vitest or jest run, or None when there is none."""
    lines = TS_TESTS.findall(out or "")
    if not lines:
        return None
    got = {kind: int(n) for n, kind in TS_RESULT.findall(lines[-1])}
    return got.get("passed", 0), got.get("failed", 0)


def _ts_pattern(seg):
    """a name segment as a regex: literal text escaped; `%s`-style and `$var` placeholders match any text."""
    return ".*".join(TS_RE_SPECIAL.sub(r"\\\1", piece) for piece in JS_PLACEHOLDER.split(seg))


def ts_runner(crate):
    """'vitest' or 'jest' from the crate's package.json (vitest wins when both are listed; vitest when neither)."""
    try:
        with open(os.path.join(crate, "package.json"), encoding="utf-8") as f:
            pkg = json.load(f)
    except (OSError, ValueError):
        return "vitest"
    deps = {}
    for key in ("dependencies", "devDependencies"):
        if isinstance(pkg, dict) and isinstance(pkg.get(key), dict):
            deps.update(pkg[key])
    return "jest" if "jest" in deps and "vitest" not in deps else "vitest"


class TsAdapter(Adapter):
    """TypeScript and JavaScript (.ts .tsx .js .jsx .mjs .cjs). Test fns: `it`/`test` (and `.each`, `.skip`, `.only`,
    `.todo`, `xit`, `fit`, `xtest`, `ftest`) inside `describe` (qualified `Describe > test name`, vitest's separator).
    Assertions: `expect(x).matcher(y)` chains. Lexical only: no type checking, no parser. A file that cannot be read
    is `parse_error`; a file that reads but does not compile shows up as a build failure in the runner."""
    name = "ts"
    default_test_cmd = "node_modules/.bin/vitest run"
    manifests = ("package.json",)

    def classify(self, path, test_globs):
        if not path.endswith(JS_EXT):
            return None
        return "test" if any_glob(path, test_globs) else "prod"

    def parse_error(self, text):
        m, _, errors, _, _, _ = _ts_parse(text)
        if errors:
            pos, msg = errors[0]
            return (_line(text, pos), msg)
        stack = []
        for i, ch in enumerate(m):
            if ch in JS_PAIR:
                stack.append((ch, i))
            elif ch in JS_PAIR.values():
                if not stack or JS_PAIR[stack[-1][0]] != ch:
                    return (_line(text, i), f"unexpected `{ch}`")
                stack.pop()
        if stack:
            ch, i = stack[-1]
            return (_line(text, i), f"`{ch}` is never closed")
        return None

    def test_fns(self, text):
        _, _, _, _, tests, _ = _ts_parse(text)
        return [TestFn(name, _line(text, t.start), markers) for name, t, markers in tests]

    def _owners(self, text):
        """[(qname, start, end)] of tests and named functions: the innermost one owns an assertion."""
        _, _, _, _, tests, fns = _ts_parse(text)
        return [(n, t.start, t.end) for n, t, _ in tests] + list(fns)

    def assertions(self, text):
        m, _, _, _, tests, fns = _ts_parse(text)
        owners = self._owners(text)
        spans = [(n, t.start, t.end) for n, t, _ in tests]
        out = []
        for e in JS_EXPECT.finditer(m):
            pos = e.start()
            open_ = e.end() - 1
            close = close_of(m, open_)
            args = args_of(text, m, open_)
            left = norm(args[0]) if args else None
            pos_after, negated, matcher, margs = close + 1, False, None, []
            while True:
                mm = JS_MEMBER.match(m, pos_after)
                if not mm:
                    break
                pos_after = mm.end()
                if mm.group(1) == "not":
                    negated = True
                elif mm.group(1) in ("resolves", "rejects"):
                    continue
                else:
                    matcher = mm.group(1)
                    break
            end = pos_after
            if matcher:
                mp = re.compile(r"\s*\(").match(m, pos_after)
                if mp:
                    margs = args_of(text, m, mp.end() - 1)
                    end = close_of(m, mp.end() - 1) + 1
            if matcher in JS_EQ and margs:
                kind = "ne" if negated else "eq"
                right = norm(margs[0])
            else:
                kind, left, right = "other", None, None
            test = next((n for n, s, t_end in reversed(spans) if s <= pos < t_end), None)
            scope = test is not None
            owner_hits = [o for o in owners if o[1] <= pos < o[2]]
            owner = max(owner_hits, key=lambda o: o[1])[0] if owner_hits else None
            call = " ".join(text[pos:end].split())
            out.append(Assertion(_line(text, pos), test, scope, kind, left, right, call, owner))
        return out

    def test_bodies(self, text):
        _, _, _, _, tests, _ = _ts_parse(text)
        return {name: (_line(text, t.start), norm(text[t.start:t.end])) for name, t, _ in tests if not t.skip or t.args[1:]}

    def calls(self, text):
        m, _, _, _, tests, fns = _ts_parse(text)
        out = {}
        for name, t, _ in tests:
            out[name] = set(JS_CALLED.findall(m[t.start:t.end]))
        for name, s, e in fns:
            out.setdefault(name, set()).update(JS_CALLED.findall(m[s:e]))
        return out

    def suppressions(self, text):
        """eslint-disable (next-line, line, block) and @ts-ignore / @ts-expect-error / @ts-nocheck, in comments only.
        reason: eslint `-- reason` after the rules; ts: text after the directive."""
        m, comments, _, _, _, _ = _ts_parse(text)
        total = text.count("\n") + 1
        out = []
        for start, end, body in comments:
            first, last = _line(text, start), _line(text, end)
            e = JS_ESLINT.match(body)
            if e:
                kind, rest = e.group(1), e.group(2)
                rules, _, reason = rest.partition("--")
                lints = " ".join([kind] + rules.split())
                region_end = {"eslint-disable-next-line": last + 1, "eslint-disable-line": last}.get(kind, total)
                out.append(Suppression(first, region_end, kind, lints, lints, bool(reason.strip())))
                continue
            t = JS_TS_DIRECTIVE.match(body)
            if t:
                kind, rest = t.group(1), t.group(2)
                reason = rest.strip().lstrip(":").strip().lstrip("-–— ").strip()
                region_end = total if kind == "@ts-nocheck" else last + 1
                out.append(Suppression(first, region_end, kind, kind, kind, bool(reason)))
        return out

    def suppression_text(self, sup):
        if sup.kind.startswith("eslint"):
            return (f"`{sup.lint_text}` added without a reason",
                    f"fix the lint, or give the suppression a reason after the rules: `// {sup.lint_text} -- why`")
        return (f"`{sup.kind}` added without a reason",
                f"fix the type error, or give the directive a reason after it: `// {sup.kind}: why`")

    def ignored_text(self, name):
        return f"test `{name}` marked skipped (skip, todo or x-prefixed)"

    def mutation_skips(self, text):
        """`Stryker disable` comments (all, next-line, or named mutators), in comments only."""
        _, comments, _, _, _, _ = _ts_parse(text)
        return [(_line(text, start), _line(text, end), " ".join(body.split())) for start, end, body in comments
                if re.match(r"\s*Stryker\s+disable\b", body)]

    def mutation_config(self, path, load):
        """Stryker's config file: stryker.conf.* / stryker.config.* (dot-prefixed too)."""
        if re.fullmatch(r"\.?stryker\.(?:conf|config)\.(?:js|mjs|cjs|ts|mts|cts|json)", os.path.basename(path)):
            return "Stryker config"
        return None

    def test_cmd_in(self, crate):
        """vitest when package.json lists vitest (or lists neither), jest when it lists only jest. The runner runs from
        the crate's own node_modules/.bin."""
        return "node_modules/.bin/jest" if ts_runner(crate) == "jest" else "node_modules/.bin/vitest run"

    def worktree_setup(self, repo, wt, project_dir):
        """a worktree has no node_modules (ignored by git): link the caller checkout's node_modules into the crate dir,
        so the runner resolves from the repo's own install. Never linked over an existing dir; the link is removed with
        the worktree, the caller's directory is not touched."""
        src = os.path.join(repo, project_dir, "node_modules")
        dst = os.path.join(wt, project_dir, "node_modules")
        if os.path.isdir(src) and os.path.isdir(os.path.dirname(dst)) and not os.path.lexists(dst):
            os.symlink(os.path.abspath(src), dst)

    def test_argv(self, cmd, path, name):
        """one named test: the file, then `-t <anchored name>` (both runners match -t as a regex on the full name).
        vitest joins describe and test names with ` > `, jest with a space; `it.each` placeholders match any value."""
        argv = shlex.split(cmd)
        jest = any("jest" in a for a in argv)
        if not jest and "run" not in argv:
            at = next((i for i, a in enumerate(argv) if "vitest" in a), len(argv) - 1)
            argv = argv[:at + 1] + ["run"] + argv[at + 1:]
        segments = name.split(" > ")
        full = (" " if jest else " > ").join(_ts_pattern(seg) for seg in segments)
        return argv + [path, "-t", f"^{full}$"]

    def outcome(self, rc, out):
        """verdict of one run of vitest or jest. Results come from the Tests summary line; a file that did not load
        (transform, missing import, syntax) is build; a filter that ran nothing is none, even at exit 0."""
        if rc is None:
            return "env"
        if rc == "timeout":
            return "timeout"
        counts = _ts_counts(out)
        if counts is not None and counts[1]:
            return "fail"
        if counts is not None and counts[0]:
            return "pass" if rc == 0 else "fail"
        if TS_BUILD.search(out):
            return "build"
        if counts is None:
            return "error"
        return "none" if rc == 0 else "error"


ADAPTERS = {"python": PythonAdapter, "rust": RustAdapter, "ts": TsAdapter}
