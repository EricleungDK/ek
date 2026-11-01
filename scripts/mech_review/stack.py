"""Stack adapters: one interface per language. Rust and Python (stdlib ast, tokenize); ts slots in as another subclass.

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
  test_argv(cmd, path, name) -> argv that runs one named test (path: the file the test is in)
  outcome(rc, output) -> verdict of one run:
      pass | fail | build | none | error | timeout | env (rc None: executable missing, toolchain absent)
  suppressions(text) -> [Suppression(line, end_line, kind, lints, lint_text, reason)]
  suppression_text(sup) -> (problem, hint) of a suppression without a reason
  parse_error(text) -> None | (line, message): the file does not parse; the checks cannot read it
"""
import ast
import io
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

    def classify(self, path, test_globs):
        raise NotImplementedError

    def test_fns(self, text):
        raise NotImplementedError

    def assertions(self, text):
        raise NotImplementedError

    def suppressions(self, text):
        raise NotImplementedError

    def calls(self, text):
        raise NotImplementedError

    def test_bodies(self, text):
        raise NotImplementedError

    def test_argv(self, cmd, path, name):
        raise NotImplementedError

    def outcome(self, rc, out):
        raise NotImplementedError

    def parse_error(self, text):
        return None

    def suppression_text(self, sup):
        return f"`{sup.lint_text}` added without a reason", "fix the lint, or give the suppression a reason"


def _innermost(spans, pos):
    """name of the innermost (name, open, close) span containing pos, or None."""
    hits = [s for s in spans if s[1] <= pos < s[2]]
    return max(hits, key=lambda s: s[1])[0] if hits else None


class RustAdapter(Adapter):
    name = "rust"
    default_test_cmd = "cargo test"

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

    def suppression_text(self, sup):
        return (f"#[{sup.kind}({sup.lint_text})] added without a reason",
                'fix the lint, or give the suppression a reason: #[allow(lint, reason = "...")]')

PY_ASSERT_EQ = {"assertEqual", "assertEquals", "assertDictEqual", "assertListEqual", "assertTupleEqual",
                "assertSetEqual", "assertMultiLineEqual", "assertSequenceEqual"}
PY_ASSERT_NE = {"assertNotEqual", "assertNotEquals"}
PY_SKIP = {"skip", "skipIf", "skipUnless", "skipif", "xfail"}
PY_NOQA = re.compile(r"#\s*noqa\b(?::\s*([A-Za-z]+\d+(?:\s*,\s*[A-Za-z]+\d+)*))?", re.I)
PY_TYPE_IGNORE = re.compile(r"#\s*type:\s*ignore\b(?:\[([^\]]*)\])?")
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


ADAPTERS = {"python": PythonAdapter, "rust": RustAdapter}
