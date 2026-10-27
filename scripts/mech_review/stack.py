"""Stack adapters: one interface per language. Rust first; python/ts slot in as more subclasses.

Adapter interface:
  classify(path, test_globs) -> "test" | "prod" | None (None: not a source file of this stack)
  test_fns(text) -> [TestFn(name, line, markers)]   markers: "ignore" (skip-like), "should_panic";
      name: fn name qualified by its enclosing mods (`m1::works`); top-level fns are bare
  assertions(text) -> [Assertion(line, fn, scope, kind, left, right, text)]  fn: enclosing test fn name or None;
      scope: inside a test fn or a #[cfg(test)] mod (production code is never in scope);
      kind: eq | ne | other (assert!(a == b) is eq); left/right: whitespace-normalized operands (eq/ne only);
      text: the whole assert call, whitespace-normalized (for messages)
"""
import re
from collections import namedtuple

from .globs import any_glob

TestFn = namedtuple("TestFn", "name line markers")
Assertion = namedtuple("Assertion", "line fn scope kind left right text owner")
Item = namedtuple("Item", "qname line is_test markers body")
CFG_TEST = re.compile(r"#\[\s*cfg\s*\(\s*test\s*\)\s*\]")
BODY_END = re.compile(r"[{;]")
ATTR = re.compile(r"#\[[^\]]*\]")
Suppression = namedtuple("Suppression", "line end_line kind lints lint_text reason")

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


def _innermost(spans, pos):
    """name of the innermost (name, open, close) span containing pos, or None."""
    hits = [s for s in spans if s[1] <= pos < s[2]]
    return max(hits, key=lambda s: s[1])[0] if hits else None


class RustAdapter(Adapter):
    name = "rust"

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
            items.append(Item(qname, m.count("\n", 0, f.start(2)) + 1, any(TEST_ATTR.match(a) for a in attrs),
                              markers, self._body(m, f.end())))
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

    def calls(self, text):
        """{fn qname: bare names it calls in its body}"""
        m, _, items = self._items(text)
        return {it.qname: set(re.findall(r"\b(\w+)\s*\(", m[it.body[0]:it.body[1]])) for it in items if it.body}

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


ADAPTERS = {"rust": RustAdapter}
