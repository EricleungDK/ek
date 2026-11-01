#!/bin/bash
# TypeScript R3 mutation on the diff: Stryker (pinned 10.0.0), replayed from real Stryker output in
# tests/fixtures/stryker (report.json = the JSON reporter's file, stdout.txt = the run's log, head/ = the source the
# mutants were generated from). The stub (MECH_TEST_STUB) answers --version, copies the fixture report into
# reports/mutation/mutation.json in the crate dir, prints the log and exits MUT_RC (or hangs with MUT_HANG=1).
source "$(dirname "$0")/lib.sh"
MR="$ROOT/scripts/mech-review.py"
FX="$ROOT/tests/fixtures/stryker"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export MECH_STUB_LOG="$T/calls.log"; : > "$MECH_STUB_LOG"

mkrepo() { local r="$T/$1"; mkdir -p "$r"; git -C "$r" init -q -b main; echo "$r"; }
put() { mkdir -p "$(dirname "$1/$2")"; cat > "$1/$2"; }
commit() { git -C "$1" add -A; git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "$2"; git -C "$1" rev-parse HEAD; }

STUB="$T/strykerstub.sh"
cat > "$STUB" <<'SH'
#!/bin/bash
echo "$(pwd -P) | $*" >> "$MECH_STUB_LOG"
case "$1" in
  --version) echo "10.0.0"; exit 0 ;;
  run)
    if [[ -n "${MUT_REPORT-}" ]]; then mkdir -p reports/mutation; cp "$MUT_REPORT" reports/mutation/mutation.json; fi
    if [[ -n "${MUT_STDOUT-}" ]]; then cat "$MUT_STDOUT"; fi
    if [[ -n "${MUT_HANG-}" ]]; then sleep 30; fi
    exit "${MUT_RC:-0}" ;;
esac
SH
chmod +x "$STUB"

# ---- pure: stryker report, kinds, log total, ranges, descriptions, config detection ----
python3 -I - "$ROOT" "$FX" <<'PY'
import json
import os
import sys
import tempfile

sys.path.insert(0, sys.argv[1] + "/scripts")
FX = sys.argv[2]
from mech_review import mutants as M
from mech_review.stack import TsAdapter
FAILS = 0


def check(name, got, want):
    global FAILS
    if got == want:
        print(f"  ok   {name}")
    else:
        FAILS += 1
        print(f"  FAIL {name}\n       want: {want!r}\n       got:  {got!r}")


def load(case):
    with open(os.path.join(FX, case, "report.json"), encoding="utf-8") as f:
        return json.load(f)


def read(*p):
    with open(os.path.join(FX, *p), encoding="utf-8") as f:
        return f.read()


check("tool registered for ts", type(M.TOOLS["ts"]).__name__, "Stryker")
check("kind: Killed is caught", M.stryker_kind("Killed"), "caught")
check("kind: Survived is missed", M.stryker_kind("Survived"), "missed")
check("kind: NoCoverage (no test reaches it) is missed", M.stryker_kind("NoCoverage"), "missed")
check("kind: Timeout is neither caught nor missed", M.stryker_kind("Timeout"), "other")
check("kind: CompileError, RuntimeError, Ignored, Pending are other",
      [M.stryker_kind(s) for s in ("CompileError", "RuntimeError", "Ignored", "Pending")], ["other"] * 4)
check("total: the run's log names the mutant count",
      M.stryker_total(read("missed", "stdout.txt")), 5)
check("total: no log line is None", M.stryker_total("no instrumenter line"), None)
check("ranges: contiguous changed lines become one range each",
      M.line_ranges([1, 2, 3, 6, 8, 9]), ["1-3", "6-6", "8-9"])
check("ranges: none", M.line_ranges([]), [])

rows = M.stryker_rows(load("missed"))
check("rows: every mutant of the report, with its file",
      sorted((f, m["mutatorName"], m["status"]) for f, m, _ in rows),
      sorted([("src/calc.ts", "ArithmeticOperator", "Survived")]
             + [("src/calc.ts", "ConditionalExpression", "NoCoverage")] * 2
             + [("src/calc.ts", "EqualityOperator", "NoCoverage")] * 2))
f0, m0, src0 = next(r for r in rows if r[1]["mutatorName"] == "ArithmeticOperator")
check("desc: mutator, the original text of the span, the replacement",
      M.stryker_desc(m0, src0), "ArithmeticOperator `a + b` -> `a - b`")
check("desc: a span over lines is joined and whitespace-normalized",
      M.stryker_desc({"mutatorName": "BlockStatement", "replacement": "{}",
                      "location": {"start": {"line": 1, "column": 1}, "end": {"line": 2, "column": 5}}},
                     "function f() {\n  x;\n}\n"),
      "BlockStatement `function f() { x;` -> `{}`")

d = tempfile.mkdtemp()
check("config: a repo's own stryker config is detected",
      M.stryker_config(d), None)
open(os.path.join(d, "stryker.conf.json"), "w").close()
check("config: stryker.conf.json is the repo's config", M.stryker_config(d), "stryker.conf.json")
d2 = tempfile.mkdtemp()
open(os.path.join(d2, "stryker.config.mjs"), "w").close()
check("config: stryker.config.mjs is the repo's config", M.stryker_config(d2), "stryker.config.mjs")

check("runner: stryker's testRunner from package.json", TsAdapter().test_cmd_in("/nope"), "node_modules/.bin/vitest run")
check("shards: 0/2 over the sorted files, as mutmut", M.shard_files(["a.ts", "b.ts", "c.ts"], "0/2"), ["a.ts", "c.ts"])

sys.exit(1 if FAILS else 0)
PY
eq "$?" 0 "stryker unit: report rows, kinds, total, ranges, desc, config detection"

# ---- CLI: `mutants --stack ts` on temp git repos. base/head: src/calc.ts changes add (line 2) and isPositive (line 6).
# mrepo <name> [head-src]: base has the unformatted lines; head is the fixture head (or head-src). sets R, B, H.
mrepo() {
  R=$(mkrepo "$1"); mkdir -p "$R/tests"
  put "$R" package.json <<'EOF'
{"name":"calc","version":"0.0.1","type":"module","devDependencies":{"vitest":"5.0.5"}}
EOF
  put "$R" src/calc.ts <<'EOF'
export function add(a: number, b: number): number {
  return a+b;
}

export function isPositive(n: number): boolean {
  return n>0;
}

export function mul(a: number, b: number): number {
  return a * b;
}

export function sub(a: number, b: number): number {
  return a - b;
}
EOF
  put "$R" tests/calc.test.ts <<'EOF'
import { it, expect } from "vitest";
import { add } from "../src/calc";

it("adds", () => {
  expect(add(0, 0)).toBe(0);
});
EOF
  B=$(commit "$R" base)
  cp "${2:-$FX/missed/head/src/calc.ts}" "$R/src/calc.ts"
  H=$(commit "$R" head)
}
# st <repo> <base> <head> [args]: mutants with the ts stack and the stub
st() { local r="$1" b="$2" h="$3"; shift 3; MECH_TEST_STUB="$STUB" python3 -I "$MR" mutants --repo "$r" --base "$b" --head "$h" --stack ts --test-paths 'tests/**' "$@"; }

mrepo missed
export MUT_REPORT="$FX/missed/report.json" MUT_STDOUT="$FX/missed/stdout.txt" MUT_RC=0
: > "$MECH_STUB_LOG"
out=$(st "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "ts MISSED mutants: exit 1"
eq "$(jq -r '[.entries[] | select(.check=="R3")] | length' <<<"$out")" 5 "ts MISSED: one entry per mutant in the diff"
eq "$(jq -r '[.entries[].line] | unique | map(tostring) | join(",")' <<<"$out")" "2,6" "ts MISSED: changed lines only (2 and 6)"
hasnt_untouched=$(jq -r '[.entries[].line] | map(select(. == 14)) | length' <<<"$out")
eq "$hasnt_untouched" 0 "ts MISSED: the untouched sub (line 14) is not a fail"
eq "$(jq -r '[.entries[] | select(.line==2)][0].problem' <<<"$out")" 'MISSED mutant src/calc.ts:2: ArithmeticOperator `a + b` -> `a - b`' "ts MISSED: problem names the mutant and its span"
eq "$(jq -r '[.entries[] | select(.line==6)][0].class' <<<"$out")" agent-fixable "ts MISSED: class agent-fixable"
eq "$(jq -r '[.entries[] | select(.check=="R3")][0].id | test("^R3-[0-9a-f]{8}$")' <<<"$out")" true "ts MISSED: finalized entry id"
eq "$(jq -r .summary <<<"$out")" "fail $H (5 fail, 0 confirm; ran: R3; skipped: R1 R2 R4)" "ts MISSED: summary"
has "$(cat "$MECH_STUB_LOG")" "run --mutate src/calc.ts:2-2,src/calc.ts:6-6 --reporters json" "ts MISSED: mutate is the changed lines only, json reporter"
has "$(cat "$MECH_STUB_LOG")" "--testRunner vitest" "ts MISSED: no repo config, so the runner comes from package.json"
has "$(cat "$MECH_STUB_LOG")" "--timeoutMS 120000" "ts MISSED: per-mutant timeout is mutant-timeout in ms"
eq "$(git -C "$R" status --porcelain | wc -l | tr -d ' ')" 0 "ts MISSED: the caller checkout is untouched"

# outside: only add's line changes in the diff; the report's line-6 mutants are outside the diff, not fails
mrepo outside "$FX/missed/head/src/calc.ts"
put "$R" src/calc.ts <<'EOF'
export function add(a: number, b: number): number {
  return a + b;
}

export function isPositive(n: number): boolean {
  return n>0;
}

export function mul(a: number, b: number): number {
  return a * b;
}

export function sub(a: number, b: number): number {
  return a - b;
}
EOF
H=$(commit "$R" head2)
out=$(st "$R" "$B" "$H"); rc=$?
eq "$(jq -r '[.entries[].line] | map(tostring) | join(",")' <<<"$out")" "2" "ts outside: only the changed line is a fail"
has "$(jq -r .checks.R3.note <<<"$out")" "4 missed outside the diff" "ts outside: the note counts the outside mutants"

# zero mutants: the report lists no file, so nothing is missed
mrepo zero
export MUT_REPORT="$FX/zero/report.json" MUT_STDOUT="$FX/zero/stdout.txt" MUT_RC=0
out=$(st "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "ts zero mutants: exit 0"
eq "$(jq -r .checks.R3.status <<<"$out")" pass "ts zero mutants: R3 pass"
eq "$(jq -r .checks.R3.note <<<"$out")" "0 mutants in the diff" "ts zero mutants: the note says so"

# baseline fails at head: a fail that names the baseline, mutants not run
mrepo baseline
export MUT_REPORT= MUT_STDOUT="$FX/baseline-fail/stdout.txt" MUT_RC=1
out=$(st "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "ts baseline fails: exit 1"
eq "$(jq -r '.entries[0].problem' <<<"$out")" "baseline tests fail at head: mutants not run" "ts baseline fails: names the baseline"
eq "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable "ts baseline fails: agent-fixable"

# budget hit before Stryker writes its report: partial (tested unknown), not blocking, named in the summary
mrepo budget
export MUT_REPORT= MUT_STDOUT="$FX/missed/stdout.txt" MUT_RC=0 MUT_HANG=1
out=$(st "$R" "$B" "$H" --mutation-budget 0.02); rc=$?
unset MUT_HANG
eq "$rc" 0 "ts budget hit with nothing missed: exit 0 (partial does not block)"
eq "$(jq -r .checks.R3.status <<<"$out")" partial "ts budget hit: R3 partial"
has "$(jq -r .summary <<<"$out")" "partial: R3" "ts budget hit: summary names partial"
has "$(jq -r '[.entries[] | select(.check=="R3")][0].problem' <<<"$out")" "R3 partial" "ts budget hit: one partial confirm entry"
eq "$(jq -r '[.entries[] | select(.check=="R3")][0].severity' <<<"$out")" confirm "ts budget hit: partial is a confirm"

# no tool: n/a (env), never a pass
mrepo notool
out=$(MECH_TEST_STUB= python3 -I "$MR" mutants --repo "$R" --base "$B" --head "$H" --stack ts --test-paths 'tests/**' --mutants-cmd "ek-no-such-stryker"); rc=$?
eq "$(jq -r .checks.R3.status <<<"$out")" n/a "ts no stryker: R3 n/a"
has "$(jq -r .checks.R3.note <<<"$out")" "stryker not installed (env)" "ts no stryker: the note names the install"
lacks "$(jq -r .summary <<<"$out")" "all pass" "ts no stryker: never all pass"

# no production file changed (docs only): skipped and the tool is never run
R=$(mkrepo docs); put "$R" package.json <<'EOF'
{"name":"calc","devDependencies":{"vitest":"5.0.5"}}
EOF
put "$R" src/calc.ts <<'EOF'
export const a = 1;
EOF
B=$(commit "$R" base)
put "$R" README.md <<'EOF'
docs
EOF
H=$(commit "$R" docs)
: > "$MECH_STUB_LOG"
out=$(st "$R" "$B" "$H"); rc=$?
eq "$(jq -r .checks.R3.status <<<"$out")" skipped "ts docs only: R3 skipped"
eq "$(wc -c < "$MECH_STUB_LOG" | tr -d ' ')" 0 "ts docs only: the stub is never run"

# project-dir: the crate is pkg/; mutants run there, crate-relative mutate, repo-root entry paths
R=$(mkrepo pd); mkdir -p "$R/pkg/tests"
put "$R" pkg/package.json <<'EOF'
{"name":"calc","devDependencies":{"vitest":"5.0.5"}}
EOF
put "$R" pkg/src/calc.ts <<'EOF'
export function add(a: number, b: number): number {
  return a+b;
}
EOF
put "$R" pkg/tests/calc.test.ts <<'EOF'
import { it, expect } from "vitest";
it("adds", () => {
  expect(1).toBe(1);
});
EOF
B=$(commit "$R" base)
put "$R" pkg/src/calc.ts <<'EOF'
export function add(a: number, b: number): number {
  return a + b;
}
EOF
H=$(commit "$R" head)
: > "$MECH_STUB_LOG"
export MUT_REPORT="$FX/missed/report.json" MUT_STDOUT="$FX/missed/stdout.txt" MUT_RC=0
out=$(MECH_TEST_STUB="$STUB" python3 -I "$MR" mutants --repo "$R" --base "$B" --head "$H" --stack ts --test-paths 'pkg/tests/**' --project-dir pkg); rc=$?
has "$(cat "$MECH_STUB_LOG")" "/pkg | run --mutate src/calc.ts:2-2" "ts project-dir: runs in the crate, crate-relative mutate"
eq "$(jq -r '[.entries[].file] | unique | join(",")' <<<"$out")" "pkg/src/calc.ts" "ts project-dir: entry paths are repo-root"

# no package.json in the crate: n/a names project-dir, never Cargo
R=$(mkrepo nomanifest); mkdir -p "$R/src"
put "$R" src/calc.ts <<'EOF'
export const a = 1;
EOF
B=$(commit "$R" base)
put "$R" src/calc.ts <<'EOF'
export const a = 2;
EOF
H=$(commit "$R" head)
out=$(MECH_TEST_STUB="$STUB" python3 -I "$MR" mutants --repo "$R" --base "$B" --head "$H" --stack ts --test-paths 'tests/**'); rc=$?
eq "$(jq -r .checks.R3.status <<<"$out")" n/a "ts no package.json: R3 n/a"
has "$(jq -r .checks.R3.note <<<"$out")" "no package.json in .: set project-dir" "ts no package.json: the note names package.json"
lacks "$(jq -r .checks.R3.note <<<"$out")" "Cargo" "ts no package.json: no Cargo text"

# the repo's own Stryker config: it is kept (no testRunner on the command line), mutate and the reporter are set there
mrepo ownconf
put "$R" stryker.conf.json <<'EOF'
{"testRunner":"vitest","checkers":[]}
EOF
H=$(commit "$R" conf)
: > "$MECH_STUB_LOG"
export MUT_REPORT="$FX/missed/report.json" MUT_STDOUT="$FX/missed/stdout.txt" MUT_RC=0
out=$(st "$R" "$B" "$H"); rc=$?
lacks "$(cat "$MECH_STUB_LOG")" "--testRunner" "ts own config: testRunner comes from the repo's config"
has "$(jq -r .checks.R3.note <<<"$out")" "stryker.conf.json" "ts own config: the note names the config"

# jest from package.json
mrepo jest
put "$R" package.json <<'EOF'
{"name":"calc","devDependencies":{"jest":"30.5.2"}}
EOF
H=$(commit "$R" jest)
: > "$MECH_STUB_LOG"
out=$(st "$R" "$B" "$H"); rc=$?
has "$(cat "$MECH_STUB_LOG")" "--testRunner jest" "ts jest: testRunner from package.json"

# unlocated: a MISSED mutant with no location cannot be placed: one confirm, not a fail
python3 -c "
import json, sys
d = json.load(open('$FX/missed/report.json'))
for m in d['files']['src/calc.ts']['mutants']:
    if m['status'] == 'Survived':
        del m['location']
json.dump(d, open('$T/unloc.json', 'w'))"
mrepo unloc
export MUT_REPORT="$T/unloc.json" MUT_STDOUT="$FX/missed/stdout.txt" MUT_RC=0
out=$(st "$R" "$B" "$H"); rc=$?
eq "$(jq -r '[.entries[] | select(.problem | test("unlocated"))][0].severity' <<<"$out")" confirm "ts unlocated: a confirm entry"
has "$(jq -r .checks.R3.note <<<"$out")" "1 unlocated" "ts unlocated: the note counts it"

# a report that cannot be read is n/a (env): a Stryker run that wrote no report never passes
mrepo noreport
export MUT_REPORT= MUT_STDOUT="$FX/missed/stdout.txt" MUT_RC=1
out=$(st "$R" "$B" "$H"); rc=$?
eq "$(jq -r .checks.R3.status <<<"$out")" n/a "ts no report: R3 n/a (env)"
lacks "$(jq -r .summary <<<"$out")" "all pass" "ts no report: never all pass"

# plan: a ts production change runs the mutants job over 4 shards
mrepo plan
out=$(python3 -I "$MR" plan --repo "$R" --base "$B" --head "$H" --stack ts --test-paths 'tests/**' --shards 4)
eq "$(jq -c '{run,count,shards}' <<<"$out")" '{"run":true,"count":4,"shards":[0,1,2,3]}' "ts plan: a production change runs 4 shards"

done_tests
