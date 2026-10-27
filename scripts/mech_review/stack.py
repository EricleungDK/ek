"""Stack adapters: one interface per language. Rust first; python/ts slot in as more subclasses.

Adapter interface:
  classify(path, test_globs) -> "test" | "prod" | None (None: not a source file of this stack)
  test_fns(text) -> [TestFn(name, line, markers)]   markers: "ignore" (skip-like; more for future stacks)
  assertions(text) -> [Assertion(line, fn, kind, subject, expected)]  fn: enclosing test fn name or None;
      kind: eq | ne | other; subject/expected: first two args of eq/ne (else None)
"""
import re
from collections import namedtuple

from .globs import any_glob

TestFn = namedtuple("TestFn", "name line markers")
Assertion = namedtuple("Assertion", "line fn kind subject expected")

RAW = re.compile(r'(?:br|r)(#*)"')
FN = re.compile(r'((?:#\[[^\]]*\]\s*)*)(?:pub(?:\s*\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?fn\s+(\w+)')
ASSERT = re.compile(r"\b(\w*assert\w*)!\s*[(\[{]")
TEST_ATTR = re.compile(r"#\[\s*(?:\w+::)*(?:test|rstest|test_case)\b")
IGNORE_ATTR = re.compile(r"#\[\s*(?:ignore\b|cfg_attr\s*\(.*\bignore\b|cfg\s*\(\s*(?:any\s*\(\s*\)|FALSE|false)\s*\)\s*\])")
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
        elif c in "rb" and (i == 0 or not _ident(text[i - 1])) and RAW.match(text, i):
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


class RustAdapter(Adapter):
    name = "rust"

    def classify(self, path, test_globs):
        if not path.endswith(".rs"):
            return None
        return "test" if any_glob(path, test_globs) else "prod"

    def _scan(self, text):
        m = mask(text)
        fns = []
        for f in FN.finditer(m):
            attrs = re.findall(r"#\[[^\]]*\]", f.group(1))
            if not any(TEST_ATTR.match(a) for a in attrs):
                continue
            markers = ["ignore"] if any(IGNORE_ATTR.match(a) for a in attrs) else []
            body = m.find("{", f.end())
            span = (body, close_of(m, body)) if body >= 0 else (f.end(), f.end())
            fns.append((TestFn(f.group(2), m.count("\n", 0, f.start(2)) + 1, markers), span))
        return m, fns

    def test_fns(self, text):
        return [t for t, _ in self._scan(text)[1]]

    def assertions(self, text):
        m, fns = self._scan(text)
        out = []
        for a in ASSERT.finditer(m):
            pos = a.start()
            fn = next((t.name for t, (s, e) in fns if s <= pos < e), None)
            name = re.sub(r"^debug_", "", a.group(1))
            kind = "eq" if name.endswith("_eq") else "ne" if name.endswith("_ne") else "other"
            subj = exp = None
            if kind in ("eq", "ne") and m[a.end() - 1] == "(":
                args = args_of(text, m, a.end() - 1)
                if len(args) >= 2:
                    subj, exp = args[0], args[1]
            out.append(Assertion(m.count("\n", 0, pos) + 1, fn, kind, subj, exp))
        return out


ADAPTERS = {"rust": RustAdapter}
