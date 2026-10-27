"""Stack adapters: one interface per language. Rust first; python/ts slot in as more subclasses.

Adapter interface:
  classify(path, test_globs) -> "test" | "prod" | None (None: not a source file of this stack)
  test_fns(text) -> [TestFn(name, line, markers)]   markers: "ignore" (skip-like; more for future stacks)
"""
import re
from collections import namedtuple

from .globs import any_glob

TestFn = namedtuple("TestFn", "name line markers")

# strings, raw strings, comments and char literals -> blanked (same length, newlines kept)
MASK = re.compile(r'//[^\n]*|/\*.*?\*/|\br(#*)"(.*?)"\1|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])\'', re.S)
FN = re.compile(r'((?:#\[[^\]]*\]\s*)*)(?:pub(?:\s*\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?fn\s+(\w+)')


def mask(text):
    return MASK.sub(lambda m: re.sub(r"[^\n]", " ", m.group(0)), text)


class Adapter:
    name = ""

    def classify(self, path, test_globs):
        raise NotImplementedError

    def test_fns(self, text):
        raise NotImplementedError


class RustAdapter(Adapter):
    name = "rust"

    def classify(self, path, test_globs):
        if not path.endswith(".rs"):
            return None
        return "test" if any_glob(path, test_globs) else "prod"

    def test_fns(self, text):
        m = mask(text)
        out = []
        for f in FN.finditer(m):
            attrs = re.findall(r"#\[[^\]]*\]", f.group(1))
            if not any(re.match(r"#\[\s*(tokio::)?test\b", a) for a in attrs):
                continue
            markers = ["ignore"] if any(re.match(r"#\[\s*ignore\b", a) for a in attrs) else []
            out.append(TestFn(f.group(2), m.count("\n", 0, f.start(2)) + 1, markers))
        return out


ADAPTERS = {"rust": RustAdapter}
