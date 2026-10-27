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

# strings, raw strings, comments and char literals -> blanked (same length, newlines kept)
MASK = re.compile(r'//[^\n]*|/\*.*?\*/|\br(#*)"(.*?)"\1|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])\'', re.S)
FN = re.compile(r'((?:#\[[^\]]*\]\s*)*)(?:pub(?:\s*\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?fn\s+(\w+)')
ASSERT = re.compile(r"\b(?:debug_)?assert(_eq|_ne|_matches)?!\s*[(\[{]")
OPEN, CLOSE = "([{", ")]}"


def mask(text):
    return MASK.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)


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
            if not any(re.match(r"#\[\s*(tokio::)?test\b", a) for a in attrs):
                continue
            markers = ["ignore"] if any(re.match(r"#\[\s*ignore\b", a) for a in attrs) else []
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
            kind = {"_eq": "eq", "_ne": "ne"}.get(a.group(1), "other")
            subj = exp = None
            if kind in ("eq", "ne") and m[a.end() - 1] == "(":
                args = args_of(text, m, a.end() - 1)
                if len(args) >= 2:
                    subj, exp = args[0], args[1]
            out.append(Assertion(m.count("\n", 0, pos) + 1, fn, kind, subj, exp))
        return out


ADAPTERS = {"rust": RustAdapter}
