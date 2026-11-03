#!/bin/bash
# TypeScript R1 red-first and R4 determinism: vitest and jest outcome mapping (captured real output in
# tests/fixtures/vitest and tests/fixtures/jest), named-test argv, runner detection from package.json, and `red`
# on temp git repos. The stub (MECH_TEST_STUB) replays the captured output for the outcome named by the leaf test name.
source "$(dirname "$0")/lib.sh"
MR="$ROOT/scripts/mech-review.py"
FX="$ROOT/tests/fixtures"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export MECH_STUB_LOG="$T/calls.log" MECH_STUB_STATE="$T/state" MECH_FX="$FX"; mkdir -p "$MECH_STUB_STATE"; : > "$MECH_STUB_LOG"

mkrepo() { local r="$T/$1"; mkdir -p "$r"; git -C "$r" init -q -b main; echo "$r"; }
put() { mkdir -p "$(dirname "$1/$2")"; cat > "$1/$2"; }
commit() { git -C "$1" add -A; git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "$2"; git -C "$1" rev-parse HEAD; }

# fake runner: replays the captured output of the outcome named for the test's leaf name in ./outcomes
# (lines `<leaf> <outcome>`; outcome: pass fail none build build-import error flaky). The runner flavour comes from argv:
# vitest is `run <file> -t <pattern>`, jest is `<file> -t <pattern>`. Logs cwd and argv to MECH_STUB_LOG.
STUB="$T/tsstub.sh"
cat > "$STUB" <<'SH'
#!/bin/bash
echo "$(pwd -P) | $*" >> "$MECH_STUB_LOG"
pat=""; prev=""
for a in "$@"; do [[ "$prev" == "-t" ]] && pat="$a"; prev="$a"; done
leaf="${pat#^}"; leaf="${leaf%\$}"; leaf="${leaf##* > }"; leaf="${leaf##* }"
flavour=jest; [[ "$1" == "run" ]] && flavour=vitest
f=outcomes; [[ -f $f ]] || f=tests/outcomes.base  # R1's checkout: base code + the PR's test files
o=$(awk -v n="$leaf" '$1 == n { print $2 }' "$f" 2>/dev/null); o="${o:-pass}"
case "$o" in
  pass)  cat "$MECH_FX/$flavour/pass.txt"; exit 0 ;;
  fail)  cat "$MECH_FX/$flavour/fail.txt"; exit 1 ;;
  none)  cat "$MECH_FX/$flavour/none.txt"; exit 0 ;;
  build) cat "$MECH_FX/$flavour/build.txt"; exit 1 ;;
  build-import) cat "$MECH_FX/vitest/build-import.txt"; exit 1 ;;
  error) printf 'boom: no test result\n'; exit 1 ;;
  flaky) n=$(( $(cat "$MECH_STUB_STATE/$leaf" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$MECH_STUB_STATE/$leaf"
         if (( n % 2 )); then cat "$MECH_FX/$flavour/fail.txt"; exit 1; fi
         cat "$MECH_FX/$flavour/pass.txt"; exit 0 ;;
esac
SH
chmod +x "$STUB"

# ---- adapter unit: runner detection, named-test argv, outcome vocabulary on captured output (pure) ----
python3 -I - "$ROOT" "$FX" <<'PY'
import os
import sys
import tempfile

sys.path.insert(0, sys.argv[1] + "/scripts")
FX = sys.argv[2]
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


def read(*p):
    with open(os.path.join(FX, *p), encoding="utf-8") as f:
        return f.read()


def pkg(devdeps):
    d = tempfile.mkdtemp()
    with open(os.path.join(d, "package.json"), "w") as f:
        f.write('{"devDependencies": {' + ", ".join(f'"{k}": "1.0.0"' for k in devdeps) + "}}")
    return d


check("runner: vitest in package.json", A.test_cmd_in(pkg(["vitest"])), "node_modules/.bin/vitest run")
check("runner: jest in package.json", A.test_cmd_in(pkg(["jest"])), "node_modules/.bin/jest")
check("runner: both listed is vitest", A.test_cmd_in(pkg(["jest", "vitest"])), "node_modules/.bin/vitest run")
check("runner: neither is the vitest default", A.test_cmd_in(pkg([])), "node_modules/.bin/vitest run")
check("runner: missing directory is the default", A.test_cmd_in("/no/such/dir"), "node_modules/.bin/vitest run")

check("argv: vitest runs the file with the anchored full name (describe > test)",
      A.test_argv("node_modules/.bin/vitest run", "tests/calc.test.ts", "Calc > adds"),
      ["node_modules/.bin/vitest", "run", "tests/calc.test.ts", "-t", "^Calc > adds$"])
check("argv: jest joins names with a space",
      A.test_argv("node_modules/.bin/jest", "tests/calc.test.ts", "Calc > adds"),
      ["node_modules/.bin/jest", "tests/calc.test.ts", "-t", "^Calc adds$"])
check("argv: a custom vitest command gets run inserted",
      A.test_argv("npx vitest", "tests/calc.test.ts", "adds"),
      ["npx", "vitest", "run", "tests/calc.test.ts", "-t", "^adds$"])
check("argv: regex characters in a name are literal",
      A.test_argv("node_modules/.bin/vitest run", "tests/calc.test.ts", "Calc > adds (1) [x]")[-1],
      "^Calc > adds \\(1\\) \\[x\\]$")
check("argv: it.each placeholders match any value",
      A.test_argv("node_modules/.bin/vitest run", "tests/calc.test.ts", "sums %i and %i")[-1],
      "^sums .* and .*$")

check("outcome: vitest pass", A.outcome(0, read("vitest", "pass.txt")), "pass")
check("outcome: vitest fail", A.outcome(1, read("vitest", "fail.txt")), "fail")
check("outcome: vitest filter matched nothing is none, even at exit 0",
      A.outcome(0, read("vitest", "none.txt")), "none")
check("outcome: vitest transform error is build", A.outcome(1, read("vitest", "build.txt")), "build")
check("outcome: vitest missing import is build", A.outcome(1, read("vitest", "build-import.txt")), "build")
check("outcome: jest pass", A.outcome(0, read("jest", "pass.txt")), "pass")
check("outcome: jest fail", A.outcome(1, read("jest", "fail.txt")), "fail")
check("outcome: jest filter matched nothing is none, even at exit 0", A.outcome(0, read("jest", "none.txt")), "none")
check("outcome: jest suite failed to run (import) is build", A.outcome(1, read("jest", "build.txt")), "build")
check("outcome: jest syntax error is build", A.outcome(1, read("jest", "build-syntax.txt")), "build")
check("outcome: no executable is env", A.outcome(None, "node_modules/.bin/vitest: not found"), "env")
check("outcome: timeout", A.outcome("timeout", ""), "timeout")
check("outcome: no test result and a failing exit is error", A.outcome(1, "boom: no test result\n"), "error")
check("outcome: no output at all is error", A.outcome(0, ""), "error")

sys.exit(1 if FAILS else 0)
PY
eq "$?" 0 "ts adapter unit: runner detection, argv, outcomes on captured output"

# ---- R1 and R4 on temp git repos. agent_repo <name>: base (describe Calc, test adds), red adds Calc > fresh,
# head fixes src. env: RED_OUT, HEAD_OUT (outcome of fresh; defaults fail at red, pass at head), RED_PROD, RED_NOTEST,
# RED_UNPARSE, PKG (devDependency: vitest|jest, default vitest). sets R, B, RED, H ----
agent_repo() {
  R=$(mkrepo "$1"); local red_out="${RED_OUT-fail}" head_out="${HEAD_OUT-pass}"
  put "$R" .gitignore <<'EOF'
node_modules/
EOF
  put "$R" package.json <<EOF
{"name":"calc","type":"module","devDependencies":{"${PKG-vitest}":"1.0.0"}}
EOF
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
  if [[ -n "${RED_NOTEST-}" ]]; then
    echo docs > "$R/README.md"
    printf 'adds pass\n' > "$R/outcomes"
  else
    put "$R" tests/calc.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
import { add } from "../src/calc";

describe("Calc", () => {
  it("adds", () => {
    expect(add(1, 2)).toBe(3);
  });
  it("fresh", () => {
    expect(add(1, 2)).toBe(3);
  });
});
EOF
    [[ -n "${RED_UNPARSE-}" ]] && put "$R" tests/calc.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
describe("Calc", () => {
  it("fresh", () => {
    expect(1).toBe(1);
EOF
    printf 'fresh %s\nadds pass\n' "$red_out" > "$R/outcomes"
    cp "$R/outcomes" "$R/tests/outcomes.base"
  fi
  if [[ -n "${RED_PROD-}" ]]; then printf '// red\n' >> "$R/src/calc.ts"; fi
  RED=$(commit "$R" "${RED_SUBJECT:-test(red): fresh}")
  printf 'fresh %s\nadds pass\n' "$head_out" > "$R/outcomes"
  put "$R" src/calc.ts <<'EOF'
export function add(a: number, b: number): number {
  return a + b; // fixed
}
EOF
  H=$(commit "$R" "feat: fix")
}

# red <repo> <base> <head> [args]: red subcommand with the ts stack and the stub
red() { local r="$1" b="$2" h="$3"; shift 3; MECH_TEST_STUB="$STUB" python3 -I "$MR" red --repo "$r" --base "$b" --head "$h" --stack ts --test-paths 'tests/**' "$@"; }

agent_repo ok
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 0 "ts red fails, head passes: exit 0"
eq "$(jq -r .checks.R1.status <<<"$out")" pass "ts R1 pass"
eq "$(jq -r .checks.R4.status <<<"$out")" pass "ts R4 pass"
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 0 confirm; ran: R1 R4; skipped: R2 R3)" "ts: summary names ran and skipped"
has "$(cat "$MECH_STUB_LOG")" "run tests/calc.test.ts -t ^Calc > fresh$" "ts vitest: named test with the anchored describe > test pattern"

RED_OUT=pass agent_repo passes
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 1 "ts: no new test fails on the base's code: exit 1"
has "$(jq -r '.entries[0].problem' <<<"$out")" "no new or changed test fails without this PR's production change: \`Calc > fresh\`" "ts red-pass names the test"
eq "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable "ts red-pass class agent-fixable"

RED_OUT=build agent_repo nobuild
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 0 "ts build failure on base counts as red, exit 0"
eq "$(jq -r '.entries | length' <<<"$out")" 0 "ts compile-red: no entry, no reviewer step"
has "$(jq -r .checks.R1.note <<<"$out")" "(1 compile-red)" "ts compile-red named in the note"

RED_OUT=none agent_repo nomatch
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 1 "ts filter that runs nothing at red is a fail, never a pass"
has "$(jq -r '.entries[0].problem' <<<"$out")" "cannot be proven red" "ts none at red names the cause"

RED_PROD=1 agent_repo prodred
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 0 "ts: tests and production in one commit: exit 0 (order does not matter)"
eq "$(jq -r .checks.R1.status <<<"$out")" pass "ts: tests with production: R1 pass"

RED_NOTEST=1 agent_repo notest
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 1 "ts red commit with no new test: exit 1"

HEAD_OUT=flaky agent_repo flaky
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 1 "ts flaky test at head: exit 1"
eq "$(jq -r '[.entries[] | select(.check=="R4")][0].class' <<<"$out")" agent-fixable "ts flaky class agent-fixable"
has "$(jq -r '[.entries[] | select(.check=="R4")][0].problem' <<<"$out")" "failed 3 of 5 runs" "ts flaky names the runs"

HEAD_OUT=none agent_repo none
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 1 "ts test that does not run at head: exit 1"
has "$(jq -r '[.entries[] | select(.check=="R4")][0].problem' <<<"$out")" "did not run at head" "ts not-run problem"

HEAD_OUT=build agent_repo buildhead
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 1 "ts test that does not build at head: exit 1"
has "$(jq -r '[.entries[] | select(.check=="R4")][0].problem' <<<"$out")" "does not build at head" "ts build-at-head problem"

RED_UNPARSE=1 agent_repo unparse
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 1 "ts unparseable test file at red: exit 1, not a crash"
has "$(jq -r '.entries | map(.problem) | join(" ")' <<<"$out")" "does not parse" "ts unparseable names the cause"

PKG=jest agent_repo jestpkg
: > "$MECH_STUB_LOG"
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 0 "ts jest from package.json: red fails, head passes: exit 0"
has "$(cat "$MECH_STUB_LOG")" "tests/calc.test.ts -t ^Calc fresh$" "ts jest: space-joined pattern, no run subcommand"

# project-dir: the crate is pkg/ (package.json, src, tests); the runner starts in the crate dir; paths stay repo-root
R=$(mkrepo pd1)
put "$R" .gitignore <<'EOF'
node_modules/
EOF
put "$R" pkg/package.json <<'EOF'
{"name":"calc","devDependencies":{"vitest":"1.0.0"}}
EOF
put "$R" pkg/src/calc.ts <<'EOF'
export function add(a: number, b: number): number {
  return a + b;
}
EOF
put "$R" pkg/tests/calc.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
import { add } from "../src/calc";

describe("Calc", () => {
  it("adds", () => {
    expect(add(1, 2)).toBe(3);
  });
});
EOF
B=$(commit "$R" base)
put "$R" pkg/tests/calc.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
import { add } from "../src/calc";

describe("Calc", () => {
  it("adds", () => {
    expect(add(1, 2)).toBe(3);
  });
  it("fresh", () => {
    expect(add(1, 2)).toBe(3);
  });
});
EOF
printf 'fresh fail\nadds pass\n' > "$R/pkg/outcomes"; cp "$R/pkg/outcomes" "$R/pkg/tests/outcomes.base"; RED=$(commit "$R" "test(red): fresh")
printf 'fresh pass\nadds pass\n' > "$R/pkg/outcomes"
put "$R" pkg/src/calc.ts <<'EOF'
export function add(a: number, b: number): number {
  return a + b; // fixed
}
EOF
H=$(commit "$R" "feat: fix")
: > "$MECH_STUB_LOG"
out=$(MECH_TEST_STUB="$STUB" python3 -I "$MR" red --repo "$R" --base "$B" --head "$H" --stack ts --test-paths 'pkg/tests/**' --project-dir pkg --head-branch agent/x); rc=$?
eq "$rc" 0 "ts project-dir: red fails, head passes: exit 0"
has "$(cat "$MECH_STUB_LOG")" "/pkg |" "ts project-dir: the runner starts in the crate dir"
has "$(cat "$MECH_STUB_LOG")" "run tests/calc.test.ts -t ^Calc > fresh$" "ts project-dir: test path is crate-relative"

# real runner, no node_modules in the repo: the runner is missing, so R1 and R4 are n/a (env), never a pass
R=$(mkrepo nomods)
put "$R" .gitignore <<'EOF'
node_modules/
EOF
put "$R" package.json <<'EOF'
{"name":"calc","devDependencies":{"vitest":"1.0.0"}}
EOF
put "$R" src/calc.ts <<'EOF'
export function add(a: number, b: number): number {
  return a + b;
}
EOF
put "$R" tests/calc.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
describe("Calc", () => {
  it("adds", () => {
    expect(1).toBe(1);
  });
});
EOF
B=$(commit "$R" base)
put "$R" tests/calc.test.ts <<'EOF'
import { describe, it, expect } from "vitest";
describe("Calc", () => {
  it("adds", () => {
    expect(1).toBe(1);
  });
  it("fresh", () => {
    expect(1).toBe(1);
  });
});
EOF
RED=$(commit "$R" "test(red): fresh")
put "$R" src/calc.ts <<'EOF'
export function add(a: number, b: number): number {
  return a + b; // fixed
}
EOF
H=$(commit "$R" "feat: fix")
out=$(env -u MECH_TEST_STUB python3 -I "$MR" red --repo "$R" --base "$B" --head "$H" --stack ts --test-paths 'tests/**' --head-branch agent/x); rc=$?
eq "$(jq -r .checks.R1.status <<<"$out")" n/a "ts no node_modules: R1 n/a"
eq "$(jq -r .checks.R4.status <<<"$out")" n/a "ts no node_modules: R4 n/a"
has "$(jq -r .checks.R1.note <<<"$out")" "node_modules/.bin/vitest" "ts no node_modules: the note names the runner"
lacks "$(jq -r .summary <<<"$out")" "all pass" "ts no node_modules: never all pass"

# real runner with node_modules in the repo: the worktree links it, the runner runs, the repo's node_modules survives
mkdir -p "$R/node_modules/.bin"
cat > "$R/node_modules/.bin/vitest" <<SH
#!/bin/bash
if grep -q 'fixed' src/calc.ts; then cat "$FX/vitest/pass.txt"; exit 0; fi
cat "$FX/vitest/fail.txt"; exit 1
SH
chmod +x "$R/node_modules/.bin/vitest"
out=$(python3 -I "$MR" red --repo "$R" --base "$B" --head "$H" --stack ts --test-paths 'tests/**' --head-branch agent/x); rc=$?
eq "$(jq -r .checks.R1.status <<<"$out")" pass "ts linked node_modules: R1 runs the real runner and passes"
eq "$(jq -r .checks.R4.status <<<"$out")" pass "ts linked node_modules: R4 runs the real runner and passes"
eq "$([[ -x "$R/node_modules/.bin/vitest" ]] && echo kept)" kept "ts linked node_modules: the repo's own node_modules survives the run"
eq "$(git -C "$R" status --porcelain | wc -l | tr -d ' ')" 0 "ts linked node_modules: the caller checkout is untouched"

done_tests
