#!/bin/bash
# TypeScript/JavaScript stack (#22): adapter parsing (test fns, assertions, suppressions, parse errors) and the
# R2 test-diff guard on temp git repos mirroring the Rust and Python cases. Pure adapter tests first.
source "$(dirname "$0")/lib.sh"
MR="$ROOT/scripts/mech-review.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ---- adapter unit: classify, manifests, test fns, markers, assertions, bodies, calls, suppressions, parse errors ----
python3 -I - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
from mech_review.stack import TsAdapter

A = TsAdapter()
FAILS = 0


def check(name, got, want):
    global FAILS
    if got == want:
        print(f"  ok   {name}")
    else:
        FAILS += 1
        print(f"  FAIL {name}\n       want: {want!r}\n       got:  {got!r}")


check("name is ts", A.name, "ts")
check("manifest is package.json", A.manifests, ("package.json",))
check("classify: test-path .ts is test", A.classify("tests/calc.test.ts", ["tests/**"]), "test")
check("classify: other .js is prod", A.classify("src/calc.js", ["tests/**"]), "prod")
check("classify: .tsx .jsx .mjs .cjs are this stack",
      [A.classify(p, ["tests/**"]) for p in ("src/a.tsx", "src/a.jsx", "src/a.mjs", "src/a.cjs")], ["prod"] * 4)
check("classify: markdown is not this stack", A.classify("README.md", ["tests/**"]), None)
check("classify: python is not this stack", A.classify("src/a.py", ["tests/**"]), None)

SRC = """import { describe, it, test, expect, fit, xit } from "vitest";

describe("Calc", () => {
  it("adds", () => {
    expect(add(1, 2)).toBe(3);
  });
  test.skip("subtracts", () => {
    expect(sub(3, 1)).toBe(2);
  });
});
describe.skip("Later", () => {
  it("parked", () => { expect(1).toBe(1); });
});
describe("Other", () => {
  it("adds", () => {
    expect(add(0, 0)).toEqual(0);
    expect(add(0, 0)).not.toBe(1);
    expect(add(0, 0)).toBeTruthy();
  });
  it.only("only one", () => {});
  it.todo("later");
  xit("disabled", () => {});
  fit("focused", () => {});
  it("calls a helper", () => { check(4); });
});
it.each([[1, 2, 3]])("sums %i and %i", (a, b, c) => {
  expect(a + b).toBe(c);
});
expect(0).toBe(0);
function check(v) {
  expect(v).toBe(4);
}
const str = "it('fake', () => {})";
// it("commented", () => {});
"""

tf = A.test_fns(SRC)
check("test fns: qualified by enclosing describes, in order",
      [f.name for f in tf],
      ["Calc > adds", "Calc > subtracts", "Later > parked", "Other > adds", "Other > only one",
       "Other > later", "Other > disabled", "Other > focused", "Other > calls a helper", "sums %i and %i"])
check("test fns: .skip, describe.skip inheritance, xit and todo are ignored",
      [(f.name, f.markers) for f in tf if f.name in ("Calc > subtracts", "Later > parked", "Other > later", "Other > disabled")],
      [("Calc > subtracts", ["ignore"]), ("Later > parked", ["ignore"]), ("Other > later", ["ignore"]),
       ("Other > disabled", ["ignore"])])
check(".only and fit are only",
      [(f.name, f.markers) for f in tf if f.name in ("Other > only one", "Other > focused")],
      [("Other > only one", ["only"]), ("Other > focused", ["only"])])
check("plain tests carry no markers", [f.markers for f in tf if f.name == "Calc > adds"], [[]])
check("test fn line is the call line", [f.line for f in tf if f.name == "Calc > adds"], [4])
check("it.each names the template (placeholders kept)", [f.name for f in tf][-1], "sums %i and %i")
check("strings and comments do not make tests", A.test_fns('const s = "it(\'x\', () => {})";\n// it("y", () => {});\n'), [])

asserts = A.assertions(SRC)
calc_adds = [a for a in asserts if a.fn == "Calc > adds"]
check("assert: toBe is eq with operands",
      [(a.kind, a.left, a.right, a.scope) for a in calc_adds], [("eq", "add(1,2)", "3", True)])
check("assert: text is the whole chain",
      calc_adds[0].text, "expect(add(1, 2)).toBe(3)")
other = [(a.kind, a.left, a.right) for a in asserts if a.fn == "Other > adds"]
check("assert: toEqual is eq, .not.toBe is ne, toBeTruthy is other",
      other, [("eq", "add(0,0)", "0"), ("ne", "add(0,0)", "1"), ("other", None, None)])
check("assert: module level expect is out of scope",
      [(a.fn, a.scope) for a in asserts if a.line == SRC[:SRC.index("expect(0)")].count("\n") + 1], [(None, False)])
helper = [a for a in asserts if a.owner == "check"]
check("assert: helper function assert has no test fn and is out of scope",
      [(a.fn, a.scope, a.kind) for a in helper], [(None, False, "eq")])

bodies = A.test_bodies(SRC)
check("test bodies: keyed by qualified name, whitespace-normalized",
      bodies["Calc > adds"][1], 'it("adds",()=>{expect(add(1,2)).toBe(3);});')
check("test bodies: body line", bodies["Calc > adds"][0], 4)

calls = A.calls(SRC)
check("calls: a test calls a helper by its bare name", "check" in calls.get("Other > calls a helper", set()), True)
check("calls: a method call is not a call", "toBe" in calls.get("Calc > adds", set()), False)

SUP = """// eslint-disable-next-line no-console -- logs on purpose
console.log(1);
// eslint-disable-next-line no-console
console.log(2);
/* @ts-ignore */
const a: number = "x";
// @ts-expect-error: intentional bad input
const b: number = "y";
// @ts-ignore
const c: number = "z";
"""
sups = A.suppressions(SUP)
check("suppressions: found in comments only",
      [(s.kind, s.line, s.reason) for s in sups],
      [("eslint-disable-next-line", 1, True), ("eslint-disable-next-line", 3, False),
       ("@ts-ignore", 5, False), ("@ts-expect-error", 7, True), ("@ts-ignore", 9, False)])
check("suppressions: a code string holding a directive is not one",
      A.suppressions('const s = "// @ts-ignore";\n'), [])
check("suppressions: eslint lints text names the rule",
      sups[1].lints, "eslint-disable-next-line no-console")
check("suppressions: next-line directive covers the next line",
      (sups[1].line, sups[1].end_line), (3, 4))

check("parse: valid source has no error", A.parse_error(SRC), None)
check("parse: an unclosed block at end of file is an error",
      A.parse_error('it("x", () => {\n  expect(1);\n') is not None, True)
check("parse: a closer that does not match its opener is an error on its line",
      A.parse_error("const a = (1;\n}\n")[0], 2)
check("parse: unterminated block comment is an error", A.parse_error("/* abc\n") is not None, True)
check("parse: a stray apostrophe in JSX-like text is not an error",
      A.parse_error('const x = <p>Don\'t</p>;\n'), None)

sys.exit(1 if FAILS else 0)
PY
eq "$?" 0 "ts adapter: classify, test fns, markers, assertions, bodies, calls, suppressions, parse errors"

done_tests
