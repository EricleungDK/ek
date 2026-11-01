#!/bin/bash
# R1 red-first and R4 determinism: `mech-review.py red` on temp git repos, test runner stubbed (MECH_TEST_STUB, like SS_STUB).
# The stub reads ./outcomes in its cwd (the checkout under test): "<test> pass|fail|build|none|flaky" per line.
source "$(dirname "$0")/lib.sh"
MR="$ROOT/scripts/mech-review.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export MECH_STUB_LOG="$T/calls.log" MECH_STUB_STATE="$T/state"; mkdir -p "$MECH_STUB_STATE"

# mkrepo <name>: fresh git repo on main, prints path
mkrepo() { local r="$T/$1"; mkdir -p "$r"; git -C "$r" init -q -b main; echo "$r"; }
# put <repo> <path>: write stdin to file (mkdir -p)
put() { mkdir -p "$(dirname "$1/$2")"; cat > "$1/$2"; }
# commit <repo> <msg>: stage all, commit, print sha
commit() { git -C "$1" add -A; git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "$2"; git -C "$1" rev-parse HEAD; }

# fake toolchain: prints cargo-shaped output for the outcome of the test named last in argv
STUB="$T/stub.sh"
cat > "$STUB" <<'SH'
#!/bin/bash
name="${*: -1}"
echo "$(pwd -P) | $*" >> "$MECH_STUB_LOG"
o=$(awk -v n="$name" '$1 == n { print $2 }' outcomes 2>/dev/null)
case "${o:-pass}" in
  pass)  printf 'running 1 test\ntest %s ... ok\n\ntest result: ok. 1 passed; 0 failed; 0 ignored\n' "$name"; exit 0 ;;
  fail)  printf 'running 1 test\ntest %s ... FAILED\n\ntest result: FAILED. 0 passed; 1 failed; 0 ignored\n' "$name"; exit 101 ;;
  build) printf 'error[E0425]: cannot find value `x` in this scope\nerror: could not compile `fixture` (lib test) due to 1 previous error\n'; exit 101 ;;
  none)  printf 'running 0 tests\n\ntest result: ok. 0 passed; 0 failed; 0 ignored\n'; exit 0 ;;
  flaky) n=$(( $(cat "$MECH_STUB_STATE/$name" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$MECH_STUB_STATE/$name"
         if (( n % 2 )); then printf 'test %s ... FAILED\n\ntest result: FAILED. 0 passed; 1 failed\n' "$name"; exit 101; fi
         printf 'test %s ... ok\n\ntest result: ok. 1 passed; 0 failed\n' "$name"; exit 0 ;;
esac
SH
chmod +x "$STUB"

# red <repo> <base> <head> [args]: red subcommand with stub runner, rust config
red() { local r="$1" b="$2" h="$3"; shift 3; MECH_TEST_STUB="$STUB" python3 -I "$MR" red --repo "$r" --base "$b" --head "$h" --stack rust --test-paths 'tests/**' "$@"; }
# red_nostub: same, no stub: the default runner (cargo) decides
red_nostub() { local r="$1" b="$2" h="$3"; shift 3; env -u MECH_TEST_STUB python3 -I "$MR" red --repo "$r" --base "$b" --head "$h" --stack rust --test-paths 'tests/**' "$@"; }

# agent_repo <name>: base (adds); red commit adds `fresh` (outcome RED_OUT, default fail); head fixes prod.
# env: RED_SUBJECT (default test(red): fresh), RED_OUT, RED_PROD=1 (red also edits src), RED_NOTEST=1 (red edits README only),
#      RED2=1 (second test(red) commit adds `other`), HEAD_OUT (outcome of fresh at head, default pass).
# sets R (repo), B (base), RED (first red commit), H (head)
agent_repo() {
  R=$(mkrepo "$1"); local red_out="${RED_OUT-fail}" head_out="${HEAD_OUT-pass}"
  put "$R" src/lib.rs <<'EOF'
pub fn add(a: i32, b: i32) -> i32 { a + b }
EOF
  put "$R" tests/a.rs <<'EOF'
#[test]
fn adds() {
    assert_eq!(2, 2);
}
EOF
  B=$(commit "$R" base)
  if [[ -n "${RED_NOTEST-}" ]]; then
    echo docs > "$R/README.md"
  else
    put "$R" tests/a.rs <<'EOF'
#[test]
fn adds() {
    assert_eq!(2, 2);
}

#[test]
fn fresh() {
    assert_eq!(add(1, 2), 3);
}
EOF
    printf 'fresh %s\n' "$red_out" > "$R/outcomes"
  fi
  if [[ -n "${RED_PROD-}" ]]; then printf '// red\n' >> "$R/src/lib.rs"; fi
  RED=$(commit "$R" "${RED_SUBJECT:-test(red): fresh}")
  if [[ -n "${RED2-}" ]]; then
    put "$R" tests/a.rs <<'EOF'
#[test]
fn adds() {
    assert_eq!(2, 2);
}

#[test]
fn fresh() {
    assert_eq!(add(1, 2), 3);
}

#[test]
fn other() {
    assert_eq!(1, 1);
}
EOF
    printf 'fresh %s\nother pass\n' "$red_out" > "$R/outcomes"
    commit "$R" "test(red): other" >/dev/null
  fi
  printf '// fixed\n' >> "$R/src/lib.rs"
  printf 'fresh %s\nadds pass\n' "$head_out" > "$R/outcomes"
  H=$(commit "$R" "feat: fix")
}

# ---- adapter unit: outcome vocabulary and test bodies (pure) ----
python3 -I - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
from mech_review.stack import RustAdapter

A = RustAdapter()
FAILS = 0


def check(name, got, want):
    global FAILS
    if got == want:
        print(f"  ok   {name}")
    else:
        FAILS += 1
        print(f"  FAIL {name}\n       want: {want!r}\n       got:  {got!r}")


check("outcome: passing result is pass", A.outcome(0, "test result: ok. 1 passed; 0 failed; 0 ignored"), "pass")
check("outcome: failing result is fail", A.outcome(101, "test result: FAILED. 0 passed; 1 failed"), "fail")
check("outcome: compile error is build", A.outcome(101, "error[E0425]: cannot find value\nerror: could not compile `x` (lib test)"), "build")
check("outcome: zero tests ran is none", A.outcome(0, "running 0 tests\n\ntest result: ok. 0 passed; 0 failed"), "none")
check("outcome: cargo error with no test result is error",
      A.outcome(101, "error: could not find `Cargo.toml` in /x or any parent directory"), "error")
check("outcome: no output at all is error", A.outcome(0, ""), "error")
check("outcome: missing toolchain (no rc) is env", A.outcome(None, "cargo: not found"), "env")
check("outcome: timeout", A.outcome("timeout", ""), "timeout")
check("outcome: one binary ran, another ran none is pass",
      A.outcome(0, "test result: ok. 0 passed; 0 failed\ntest result: ok. 1 passed; 0 failed"), "pass")
check("outcome: a failure in any binary is fail",
      A.outcome(101, "test result: ok. 2 passed; 0 failed\ntest result: FAILED. 0 passed; 1 failed"), "fail")

src = "#[test]\nfn adds() {\n    assert_eq!(1 + 1, 2);\n}\n\nfn helper() {}\n"
bodies = A.test_bodies(src)
check("test_bodies: only #[test] fns", sorted(bodies), ["adds"])
check("test_bodies: line of the fn", bodies["adds"][0], 2)
check("test_bodies: whitespace-only edit keeps the body",
      A.test_bodies("#[test]\nfn adds() {\n        assert_eq!(1 + 1,   2);\n}\n")["adds"][1], bodies["adds"][1])
check("test_bodies: changed assert changes the body",
      A.test_bodies(src.replace("2);", "3);"))["adds"][1] != bodies["adds"][1], True)
check("test_bodies: mod-qualified name",
      sorted(A.test_bodies("mod m1 {\n#[test]\nfn works() { assert!(true); }\n}\n")), ["m1::works"])

sys.exit(1 if FAILS else 0)
PY
eq "$?" 0 "adapter unit: outcome vocabulary and test bodies"

# ---- argv: default runner is cargo; stub replaces only the executable ----
mkdir -p "$T/bin"; cp "$STUB" "$T/bin/cargo"
agent_repo argv
out=$(env -u MECH_TEST_STUB PATH="$T/bin:$PATH" python3 -I "$MR" red --repo "$R" --base "$B" --head "$H" --stack rust --test-paths 'tests/**' --head-branch agent/x)
has "$(cat "$MECH_STUB_LOG")" "| test -- --exact fresh" "default runner runs cargo test -- --exact NAME"
rm -f "$MECH_STUB_LOG"
out=$(red "$R" "$B" "$H" --head-branch feat/x --test-cmd "cargo test --all-features")
has "$(cat "$MECH_STUB_LOG")" "| test --all-features -- --exact fresh" "--test-cmd replaces the default command"

# ---- R1 skips: never a fail, reason in the note, R4 still runs ----
agent_repo skip1
out=$(red "$R" "$B" "$H" --head-branch feat/x); rc=$?
eq "$rc" 0 "non-agent branch: exit 0"
eq "$(jq -r .checks.R1.status <<<"$out")" skipped "non-agent branch: R1 skipped"
has "$(jq -r .checks.R1.note <<<"$out")" "agent/" "non-agent branch: note names the prefix"
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 0 confirm; ran: R4; skipped: R1 R2 R3)" "red summary names R1 skipped and R2 not run"
out=$(red "$R" "$B" "$H"); eq "$(jq -r .checks.R1.status <<<"$out")" skipped "no --head-branch: R1 skipped"
out=$(red "$R" "$B" "$H" --head-branch agent/x --agent-prefix bot/)
eq "$(jq -r .checks.R1.status <<<"$out")" skipped "--agent-prefix bot/ does not match agent/x: R1 skipped"
out=$(red "$R" "$B" "$H" --head-branch bot/x --agent-prefix bot/)
eq "$(jq -r .checks.R1.status <<<"$out")" fail "--agent-prefix bot/ matches bot/x: R1 runs"

put "$R" docs/notes.md <<<"just docs"; D=$(commit "$R" docs)
out=$(red "$R" "$H" "$D" --head-branch agent/d); rc=$?
eq "$rc" 0 "docs-only agent branch: exit 0"
eq "$(jq -r .checks.R1.status <<<"$out")" skipped "docs-only agent branch: R1 skipped"
has "$(jq -r .checks.R1.note <<<"$out")" "no production file changed" "docs-only: note says no production file changed"
eq "$(jq -r .checks.R4.note <<<"$out")" "0 new or changed tests" "docs-only: R4 ran, no tests touched"

# ---- R1 fails ----
agent_repo r1nored RED_SUBJECT="test: fresh"
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 1 "no red commit: exit 1"
eq "$(jq -r .checks.R1.status <<<"$out")" fail "no red commit: R1 fail"
eq "$(jq -r '.entries[0].check' <<<"$out")" R1 "no red commit: entry check R1"
eq "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable "no red commit: agent-fixable"
has "$(jq -r '.entries[0].problem' <<<"$out")" "no test(red) commit" "no red commit: problem"

agent_repo r1prod RED_PROD=1
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 1 "red touches production: exit 1"
eq "$(jq -r '.entries[0].file' <<<"$out")" src/lib.rs "red touches production: entry names the file"
has "$(jq -r '.entries[0].problem' <<<"$out")" "touches production" "red touches production: problem"

agent_repo r1pass RED_OUT=pass
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 1 "new test passes at red: exit 1"
has "$(jq -r '.entries[0].problem' <<<"$out")" "fresh" "new test passes at red: names the test"
has "$(jq -r '.entries[0].problem' <<<"$out")" "passes at the red commit" "new test passes at red: problem"
has "$(jq -r '.entries[0].id' <<<"$out")" "R1-" "new test passes at red: R1 id"
eq "$(jq -r '.entries[0].file' <<<"$out")" tests/a.rs "new test passes at red: file"
eq "$(jq -r '.entries[0].line' <<<"$out")" 7 "new test passes at red: line of the fn at red"

agent_repo r1ok
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 0 "red fails, head passes: exit 0"
eq "$(jq -r .checks.R1.status <<<"$out")" pass "red fails: R1 pass"
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 0 confirm; ran: R1 R4; skipped: R2 R3)" "red ok summary"
eq "$(jq -r .checks.R1.note <<<"$out")" "1 red test(s) fail at the red commit" "red ok: note counts red tests"

agent_repo r1build RED_OUT=build
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 0 "compile-red: exit 0 (confirm only)"
eq "$(jq -r '.entries[0].severity' <<<"$out")" confirm "compile-red: confirm entry"
has "$(jq -r '.entries[0].problem' <<<"$out")" "compile-red" "compile-red: problem names it"
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 1 confirm; ran: R1 R4; skipped: R2 R3)" "compile-red: summary counts the confirm"

agent_repo r1notest RED_NOTEST=1
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 1 "red commit adds no test: exit 1"
has "$(jq -r '.entries[0].problem' <<<"$out")" "adds no new test" "red adds no test: problem"

agent_repo r1first RED2=1
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 0 "first test(red) commit is the one checked (second one would pass)"
eq "$(jq -r .checks.R1.status <<<"$out")" pass "first test(red) used"

# ---- R1 env: no toolchain → n/a, never pass ----
agent_repo r1env
out=$(red_nostub "$R" "$B" "$H" --head-branch agent/x --test-cmd "ek-no-such-toolchain test"); rc=$?
eq "$rc" 0 "toolchain absent: no entries, exit 0"
eq "$(jq -r .checks.R1.status <<<"$out")" n/a "toolchain absent: R1 n/a"
has "$(jq -r .checks.R1.note <<<"$out")" "toolchain absent" "toolchain absent: R1 note"
eq "$(jq -r .checks.R4.status <<<"$out")" n/a "toolchain absent: R4 n/a"
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 0 confirm; ran: none; skipped: R2 R3; n/a: R1 R4)" "toolchain absent: summary names n/a"

# ---- the caller's checkout is never moved ----
agent_repo r1tree
echo dirty >> "$R/src/lib.rs"; echo junk > "$R/untracked.txt"
before=$(git -C "$R" rev-parse HEAD); st=$(git -C "$R" status --porcelain)
red "$R" "$B" "$H" --head-branch agent/x >/dev/null
eq "$(git -C "$R" rev-parse HEAD)" "$before" "checkout: HEAD unchanged"
eq "$(git -C "$R" status --porcelain)" "$st" "checkout: working tree unchanged"
eq "$(git -C "$R" worktree list | wc -l)" 1 "checkout: no worktree left behind"

# ---- R4: new or changed tests run 5x at head ----
agent_repo r4flake HEAD_OUT=flaky
rm -rf "$MECH_STUB_STATE"/* ; : > "$MECH_STUB_LOG"
out=$(red "$R" "$B" "$H" --head-branch feat/x); rc=$?
eq "$rc" 1 "flaky test: exit 1"
eq "$(grep -c -- '--exact fresh' "$MECH_STUB_LOG")" 5 "flaky test: fresh ran 5x at head"
eq "$(jq -r .checks.R4.status <<<"$out")" fail "flaky test: R4 fail"
eq "$(jq -r '.entries[0].check' <<<"$out")" R4 "flaky test: entry check R4"
eq "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable "flaky test: agent-fixable"
has "$(jq -r '.entries[0].problem' <<<"$out")" "failed 3 of 5 runs" "flaky test: problem counts failed runs"
has "$(jq -r '.entries[0].id' <<<"$out")" "R4-" "flaky test: R4 id"
id1=$(jq -r '.entries[0].id' <<<"$out")
put "$R" notes.txt <<<"moved"; H2=$(commit "$R" "shift lines")
rm -rf "$MECH_STUB_STATE"/*
out=$(red "$R" "$B" "$H2" --head-branch feat/x)
eq "$(jq -r '.entries[0].id' <<<"$out")" "$id1" "flaky test: id is stable when the head moves"

agent_repo r4pass
rm -rf "$MECH_STUB_STATE"/* ; : > "$MECH_STUB_LOG"
out=$(red "$R" "$B" "$H" --head-branch feat/x); rc=$?
eq "$rc" 0 "stable test: exit 0"
eq "$(grep -c -- '--exact fresh' "$MECH_STUB_LOG")" 5 "stable test: 5 runs at head"
eq "$(grep -c -- '--exact adds' "$MECH_STUB_LOG")" 0 "unchanged test is not re-run"
eq "$(jq -r .checks.R4.status <<<"$out")" pass "stable test: R4 pass"

agent_repo r4changed
put "$R" tests/a.rs <<'EOF'
#[test]
fn adds() {
    assert_eq!(2, 2);
    assert_eq!(3, 3);
}

#[test]
fn fresh() {
    assert_eq!(add(1, 2), 3);
}
EOF
C=$(commit "$R" "tighten adds")
: > "$MECH_STUB_LOG"
out=$(red "$R" "$H" "$C" --head-branch feat/x)
eq "$(grep -c -- '--exact adds' "$MECH_STUB_LOG")" 5 "changed test: adds re-run 5x at head"

agent_repo r4build HEAD_OUT=build
out=$(red "$R" "$B" "$H" --head-branch feat/x); rc=$?
eq "$rc" 1 "does not build at head: exit 1"
has "$(jq -r '[.entries[].problem] | join(" ")' <<<"$out")" "does not build" "does not build at head: problem"

agent_repo r4none HEAD_OUT=none
out=$(red "$R" "$B" "$H" --head-branch feat/x); rc=$?
eq "$rc" 1 "test ran zero times at head: exit 1"
has "$(jq -r '[.entries[].problem] | join(" ")' <<<"$out")" "did not run" "zero-run test: problem"

# ---- all: every implemented check; r2 and red name what they did not run ----
agent_repo allrun
out=$(MECH_TEST_STUB="$STUB" python3 -I "$MR" all --repo "$R" --base "$B" --head "$H" --stack rust --test-paths 'tests/**' --head-branch agent/x); rc=$?
eq "$rc" 0 "all: exit 0"
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 0 confirm; ran: R1 R2 R4; skipped: R3)" "all: runs R1 R2 R4"
out=$(python3 -I "$MR" r2 --repo "$R" --base "$B" --head "$H" --stack rust --test-paths 'tests/**')
has "$(jq -r .checks.R1.note <<<"$out")" "not run by r2" "r2: R1 note says not run by r2"
has "$(jq -r .checks.R4.note <<<"$out")" "not run by r2" "r2: R4 note says not run by r2"
eq "$(jq -r .checks.R3.note <<<"$out")" "not implemented" "r2: R3 still not implemented"

# ---- help names the red subcommand and the new inputs ----
has "$(python3 -I "$MR" --help)" "--head-branch" "help: --head-branch"
has "$(python3 -I "$MR" --help)" "--agent-prefix" "help: --agent-prefix"
has "$(python3 -I "$MR" --help)" "--test-cmd" "help: --test-cmd"
has "$(python3 -I "$MR" --help)" "red" "help: red subcommand"

# ---- merge: one envelope from the r2 and red jobs; a missing job never hides the other ----
python3 -I - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
from mech_review import merge as M

H = "a" * 40
BASE = "b" * 40
FAILS = 0


def check(name, cond, detail=""):
    global FAILS
    if cond:
        print(f"  ok   {name}")
    else:
        FAILS += 1
        print(f"  FAIL {name}\n       {detail}")


def env(checks, entries):
    fails = sum(1 for e in entries if e["severity"] == "fail")
    return {"ek": "0.1.1", "base": BASE, "head": H, "checks": checks, "entries": entries,
            "summary": f"{'fail' if fails else 'pass'} {H}"}


def ent(check_name, eid, sev="fail", file="tests/a.rs"):
    return {"id": eid, "check": check_name, "class": "agent-fixable", "severity": sev, "file": file, "line": 3,
            "problem": "p", "hint": "h", "forbidden": "f"}


r2 = env({"R1": {"status": "skipped", "note": "not run by r2"}, "R2": {"status": "fail", "note": "1 fail, 0 confirm"},
          "R3": {"status": "skipped", "note": "not implemented"}, "R4": {"status": "skipped", "note": "not run by r2"}},
         [ent("R2", "R2-11111111")])
red = env({"R1": {"status": "pass", "note": "ok"}, "R2": {"status": "skipped", "note": "not run by red"},
           "R3": {"status": "skipped", "note": "not implemented"}, "R4": {"status": "fail", "note": "1 flaky"}},
          [ent("R4", "R4-22222222")])

m = M.merge({"r2": r2, "red": red}, {})
check("both: R2 from r2 job", m["checks"]["R2"]["status"] == "fail", str(m["checks"]))
check("both: R1 and R4 from red job", m["checks"]["R1"]["status"] == "pass" and m["checks"]["R4"]["status"] == "fail", str(m["checks"]))
check("both: entries from both jobs", sorted(e["id"] for e in m["entries"]) == ["R2-11111111", "R4-22222222"], str(m["entries"]))
check("both: summary names ran and skipped", m["summary"] == f"fail {H} (2 fail, 0 confirm; ran: R1 R2 R4; skipped: R3)", m["summary"])
check("both: head and base kept", m["head"] == H and m["base"] == BASE, str(m))

m = M.merge({"r2": r2, "red": None}, {"red": "no JSON from the job (see its log)"})
check("red missing: r2 entries still there", "R2-11111111" in [e["id"] for e in m["entries"]], str(m["entries"]))
check("red missing: R1 and R4 fail with a note", m["checks"]["R1"]["status"] == "fail" and m["checks"]["R4"]["status"] == "fail"
      and "no JSON" in m["checks"]["R4"]["note"], str(m["checks"]))
ci = [e for e in m["entries"] if e["check"] == "CI"]
check("red missing: one CI fail entry naming the job", len(ci) == 1 and ci[0]["severity"] == "fail" and "red" in ci[0]["problem"], str(ci))
check("red missing: summary is not pass", m["summary"].startswith("fail "), m["summary"])

m = M.merge({"r2": None, "red": red}, {"r2": "guard exit 2"})
check("guard missing: red entries still there", "R4-22222222" in [e["id"] for e in m["entries"]], str(m["entries"]))
check("guard missing: R2 fail with a note", m["checks"]["R2"]["status"] == "fail" and "guard exit 2" in m["checks"]["R2"]["note"], str(m["checks"]))

sys.exit(1 if FAILS else 0)
PY
eq "$?" 0 "merge: one envelope, crash in one job keeps the other's entries"

done_tests
