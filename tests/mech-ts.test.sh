#!/bin/bash
# TypeScript/JavaScript stack (#22): adapter parsing (test fns, assertions, suppressions, parse errors) and the
# R2 test-diff guard on temp git repos mirroring the Rust and Python cases. Pure adapter tests first.
source "$(dirname "$0")/lib.sh"
MR="$ROOT/scripts/mech-review.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# mkrepo <name>: fresh git repo on main, prints path
mkrepo() { local r="$T/$1"; mkdir -p "$r"; git -C "$r" init -q -b main; echo "$r"; }
# put <repo> <path>: write stdin to file (mkdir -p)
put() { mkdir -p "$(dirname "$1/$2")"; cat > "$1/$2"; }
# commit <repo> <msg>: stage all, commit, print sha
commit() { git -C "$1" add -A; git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "$2"; git -C "$1" rev-parse HEAD; }

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
      bodies["Calc > adds"][1], 'it("adds",()=>{expect(add(1,2)).toBe(3);})')
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

# ---- R2 on temp git repos (ts stack): mirrors the Rust and Python guard cases ----
# mr <repo> <base> <head> [args]: r2 with the ts stack
mr() { local r="$1" b="$2" h="$3"; shift 3; python3 -I "$MR" r2 --repo "$r" --base "$b" --head "$h" --stack ts --test-paths 'tests/**' "$@"; }
# tsrepo <name>: base with src/calc.ts (add) and tests/calc.test.ts (describe Calc > adds). sets R, B
tsrepo() {
  R=$(mkrepo "$1")
  put "$R" src/calc.ts <<'EOF'
export function add(a: number, b: number): number {
  return a + b;
}
EOF
  put "$R" tests/calc.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
import { add } from "../src/calc";

describe("Calc", () => {
  it("adds", () => {
    expect(add(1, 2)).toBe(3);
  });
});
EOF
  B=$(commit "$R" base)
}
TEST_ADDS_BODY='import { describe, it, expect } from "vitest";
import { add } from "../src/calc";

describe("Calc", () => {
  it("adds", () => {
    expect(add(1, 2)).toBe(3);
  });
});'

# ---- R2 slice 1: clean change passes, skipped checks named ----
tsrepo clean
put "$R" tests/calc.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
import { add } from "../src/calc";

describe("Calc", () => {
  it("adds", () => {
    expect(add(1, 2)).toBe(3);
  });
  it("adds zero", () => {
    expect(add(0, 2)).toBe(2);
  });
});
EOF
H=$(commit "$R" "add test")
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "ts clean exit 0"
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 0 confirm; ran: R2; skipped: R1 R3 R4)" "ts clean summary names skipped checks"

# ---- R2 slice 2: skip, only, describe.skip, todo ----
tsrepo skip
put "$R" tests/calc.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
import { add } from "../src/calc";

describe("Calc", () => {
  it.skip("adds", () => {
    expect(add(1, 2)).toBe(3);
  });
});
EOF
H=$(commit "$R" cheat)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "it.skip: exit 1"
eq "$(jq -r '.entries[0].check' <<<"$out")" R2 "it.skip: R2 entry"
eq "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable "it.skip: agent-fixable"
eq "$(jq -r '.entries[0].severity' <<<"$out")" fail "it.skip: fail"
has "$(jq -r '.entries[0].problem' <<<"$out")" "Calc > adds" "it.skip names the test"
has "$(jq -r '.entries[0].problem' <<<"$out")" "skipped" "it.skip says skipped"

tsrepo only
put "$R" tests/calc.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
import { add } from "../src/calc";

describe("Calc", () => {
  it.only("adds", () => {
    expect(add(1, 2)).toBe(3);
  });
});
EOF
H=$(commit "$R" only)
out=$(mr "$R" "$B" "$H")
eq "$(jq -r '.entries[0].severity' <<<"$out")" fail "it.only: fail"
has "$(jq -r '.entries[0].problem' <<<"$out")" "only" "it.only says only"

tsrepo dskip
put "$R" tests/calc.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
import { add } from "../src/calc";

describe.skip("Calc", () => {
  it("adds", () => {
    expect(add(1, 2)).toBe(3);
  });
});
EOF
H=$(commit "$R" dskip)
out=$(mr "$R" "$B" "$H")
eq "$(jq -r '[.entries[] | select(.check=="R2")] | length' <<<"$out")" 1 "describe.skip marks the test inside it (one entry)"
has "$(jq -r '.entries[0].problem' <<<"$out")" "Calc > adds" "describe.skip names the inner test"

tsrepo todo
put "$R" tests/calc.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
import { add } from "../src/calc";

describe("Calc", () => {
  it("adds", () => {
    expect(add(1, 2)).toBe(3);
  });
  it.todo("adds big");
});
EOF
H=$(commit "$R" todo)
out=$(mr "$R" "$B" "$H")
eq "$(jq -r '.entries[0].severity' <<<"$out")" fail "it.todo added: fail (a todo is a skip)"

tsrepo xit
put "$R" tests/calc.test.ts <<'EOF'
import { describe, it, expect, xit } from "vitest";
import { add } from "../src/calc";

describe("Calc", () => {
  xit("adds", () => {
    expect(add(1, 2)).toBe(3);
  });
});
EOF
H=$(commit "$R" xit)
out=$(mr "$R" "$B" "$H")
eq "$(jq -r '.entries[0].severity' <<<"$out")" fail "xit: fail"

# ---- R2 slice 3: suppressions need a reason (eslint `-- reason`, ts directive text) ----
tsrepo eslint-noreason
put "$R" src/calc.ts <<'EOF'
export function add(a: number, b: number): number {
  // eslint-disable-next-line no-console
  console.log(a);
  return a + b;
}
EOF
H=$(commit "$R" noreason)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "eslint-disable without reason: exit 1"
eq "$(jq -r '.entries[0].file' <<<"$out")" src/calc.ts "eslint-disable: file"
has "$(jq -r '.entries[0].problem' <<<"$out")" "eslint-disable-next-line no-console" "eslint-disable names the rule"

tsrepo eslint-reason
put "$R" src/calc.ts <<'EOF'
export function add(a: number, b: number): number {
  // eslint-disable-next-line no-console -- debug log on purpose
  console.log(a);
  return a + b;
}
EOF
H=$(commit "$R" reason)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "eslint-disable with reason: exit 0"

tsrepo ts-noreason
put "$R" src/calc.ts <<'EOF'
export function add(a: number, b: number): number {
  // @ts-ignore
  return a + "x";
}
EOF
H=$(commit "$R" tsnoreason)
out=$(mr "$R" "$B" "$H")
eq "$(jq -r '.entries[0].severity' <<<"$out")" fail "@ts-ignore without reason: fail"
has "$(jq -r '.entries[0].problem' <<<"$out")" "@ts-ignore" "@ts-ignore named"

tsrepo ts-reason
put "$R" src/calc.ts <<'EOF'
export function add(a: number, b: number): number {
  // @ts-expect-error: the string is the bad input under test
  return a + "x";
}
EOF
H=$(commit "$R" tsreason)
out=$(mr "$R" "$B" "$H")
eq "$(jq -r '.entries | length' <<<"$out")" 0 "@ts-expect-error with reason: no entry"

# ---- R2 slice 4: removed test, rename, expected value, asserts dropped, replaced ----
tsrepo removed
put "$R" tests/calc.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
import { add } from "../src/calc";

describe("Calc", () => {
});
EOF
H=$(commit "$R" removed)
out=$(mr "$R" "$B" "$H")
eq "$(jq -r '.entries[0].severity' <<<"$out")" fail "removed test: fail"
has "$(jq -r '.entries[0].problem' <<<"$out")" "test fn \`Calc > adds\` removed" "removed test named"

tsrepo renamed
put "$R" tests/calc.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
import { add } from "../src/calc";

describe("Calc", () => {
  it("sums two numbers", () => {
    expect(add(1, 2)).toBe(3);
  });
});
EOF
H=$(commit "$R" renamed)
out=$(mr "$R" "$B" "$H")
eq "$(jq -r '.entries | length' <<<"$out")" 0 "renamed test with the same asserts is not a removal"

tsrepo expected
put "$R" tests/calc.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
import { add } from "../src/calc";

describe("Calc", () => {
  it("adds", () => {
    expect(add(1, 2)).toBe(4);
  });
});
EOF
H=$(commit "$R" expected)
out=$(mr "$R" "$B" "$H")
eq "$(jq -r '.entries[0].severity' <<<"$out")" confirm "changed expected value: confirm"
has "$(jq -r '.entries[0].problem' <<<"$out")" "was 3, now 4" "expected value names was and now"

tsrepo dropped
put "$R" tests/calc.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
import { add } from "../src/calc";

describe("Calc", () => {
  it("adds", () => {
    expect(add(1, 2)).toBe(3);
    expect(add(2, 2)).toBe(4);
  });
});
EOF
B2=$(commit "$R" two-asserts)
put "$R" tests/calc.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
import { add } from "../src/calc";

describe("Calc", () => {
  it("adds", () => {
    expect(add(1, 2)).toBe(3);
  });
});
EOF
H=$(commit "$R" dropped)
out=$(mr "$R" "$B2" "$H")
eq "$(jq -r '.entries[0].severity' <<<"$out")" fail "dropped assert: fail"
has "$(jq -r '.entries[0].problem' <<<"$out")" "dropped from 2 to 1" "dropped assert counts"

tsrepo replaced
put "$R" tests/calc.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
import { add } from "../src/calc";

describe("Calc", () => {
  it("adds", () => {
    expect(add(1, 2)).toBeTruthy();
  });
});
EOF
H=$(commit "$R" replaced)
out=$(mr "$R" "$B" "$H")
eq "$(jq -r '.entries[0].severity' <<<"$out")" confirm "assert replaced in place: confirm"

tsrepo helper
put "$R" tests/calc.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
import { add } from "../src/calc";

function check(a: number, b: number) {
  expect(a).toBe(b);
}

describe("Calc", () => {
  it("adds", () => {
    check(add(1, 2), 3);
  });
});
EOF
H=$(commit "$R" helper)
out=$(mr "$R" "$B" "$H")
eq "$(jq -r '.entries | length' <<<"$out")" 0 "assert moved into a helper the test calls: no entry"

tsrepo unparse
put "$R" tests/calc.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
import { add } from "../src/calc";

describe("Calc", () => {
  it("adds", () => {
    expect(add(1, 2)).toBe(3);
EOF
H=$(commit "$R" unparse)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "unparseable test file: exit 1 (truthful fail)"
has "$(jq -r '.entries[0].problem' <<<"$out")" "does not parse" "unparseable names the cause"

tsrepo protected
mkdir -p "$R/.github/workflows"; echo "x" > "$R/.github/workflows/ci.yml"; H=$(commit "$R" ci)
out=$(python3 -I "$MR" r2 --repo "$R" --base "$B" --head "$H" --stack ts --test-paths 'tests/**' --protected-paths '.github/**')
eq "$(jq -r '.entries[0].class' <<<"$out")" needs-human "ts protected path: needs-human"


done_tests
