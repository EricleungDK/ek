#!/bin/bash
# R3 mutation on the diff for python (mutmut 3.8.1). Fixtures in tests/fixtures/mutmut are real mutmut output:
#   <case>/results.txt   `mutmut results --all True` after a run (killed, survived, no tests, not checked)
#   <case>/show/<name>.txt   `mutmut show <name>` for each survivor (diff of the mutated function, not the file)
#   <case>/stdout.txt    the run's message when mutmut stops early or the baseline fails
#   head/src/calc/core.py   the head source the mutants were generated from (line numbers come from it)
# Pure parse tests first; then `mutants` on temp git repos, mutmut stubbed (MECH_TEST_STUB) to replay the fixtures.
source "$(dirname "$0")/lib.sh"
MR="$ROOT/scripts/mech-review.py"
FX="$ROOT/tests/fixtures/mutmut"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export MECH_STUB_LOG="$T/calls.log" MECH_FX="$FX"; : > "$MECH_STUB_LOG"

# ---- pure: parsing of mutmut output, config and shard split ----
python3 -I - "$ROOT" <<'PY'
import os
import sys
import tempfile

ROOT = sys.argv[1]
sys.path.insert(0, os.path.join(ROOT, "scripts"))
FX = os.path.join(ROOT, "tests", "fixtures", "mutmut")
FAILS = 0


def check(name, got, want):
    global FAILS
    if got == want:
        print(f"  ok   {name}")
    else:
        FAILS += 1
        print(f"  FAIL {name}\n       want: {got!r} == {want!r}")


from mech_review import mutants as M  # noqa: E402


def read(*parts):
    with open(os.path.join(FX, *parts), encoding="utf-8") as f:
        return f.read()


check("results: missed fixture rows, in order",
      M.parse_results(read("missed", "results.txt")),
      [("calc.core.x_add__mutmut_1", "survived"),
       ("calc.core.x_is_positive__mutmut_1", "no tests"),
       ("calc.core.x_is_positive__mutmut_2", "no tests"),
       ("calc.core.x_mul__mutmut_1", "killed"),
       ("calc.core.x_sub__mutmut_1", "survived")])
check("results: partial fixture keeps not checked rows",
      [s for _, s in M.parse_results(read("partial", "results.txt"))].count("not checked"), 1)
check("results: empty output is no rows", M.parse_results(read("zero", "results.txt")), [])
check("results: noise lines (warnings, progress) are ignored",
      M.parse_results("UserWarning: x\n    calc.core.x_add__mutmut_1: killed\n⠋ Running\n"),
      [("calc.core.x_add__mutmut_1", "killed")])

check("show: removed and added line of the mutated function",
      M.parse_show(read("missed", "show", "calc.core.x_add__mutmut_1.txt")),
      ("return a + b", "return a - b"))
check("show: a mutant with no diff is None", M.parse_show("# x: killed\n"), None)

HEAD = read("head", "src", "calc", "core.py")
check("locate: file line of the removed text inside the named function",
      M.locate(HEAD, "calc.core.x_add__mutmut_1", "return a + b"), 2)
check("locate: second function, same kind of line",
      M.locate(HEAD, "calc.core.x_sub__mutmut_1", "return a - b"), 14)
check("locate: a function that is not in the file is None",
      M.locate(HEAD, "calc.core.x_nope__mutmut_1", "return a + b"), None)

check("config: appends a [tool.mutmut] table for the changed files",
      M.add_mutmut_table("[project]\nname = 'x'\n", ["src"], ["src/calc/core.py"]).splitlines()[-3:],
      ["[tool.mutmut]", 'source_paths = ["src"]', 'only_mutate = ["src/calc/core.py"]'])
check("config: the repo's own [tool.mutmut] is not overridden (None)",
      M.add_mutmut_table("[tool.mutmut]\nsource_paths = ['src']\n", ["src"], ["src/a.py"]), None)
check("config: a [tool.mutmut.sub] table counts as the repo's own too",
      M.add_mutmut_table("[tool.mutmut.x]\na = 1\n", ["src"], ["src/a.py"]), None)
check("config: a missing pyproject is created with the table",
      M.add_mutmut_table(None, ["src"], ["src/a.py"]).startswith("[tool.mutmut]"), True)
check("config: glob characters in a path are literal for mutmut's fnmatch",
      M.add_mutmut_table("", ["src"], ["src/[x].py"]).splitlines()[-1], 'only_mutate = ["src/[[]x].py"]')

check("shards: 0/2 takes every other file, 1/2 the rest",
      (M.shard_files(["a.py", "b.py", "c.py"], "0/2"), M.shard_files(["a.py", "b.py", "c.py"], "1/2")),
      (["a.py", "c.py"], ["b.py"]))
check("shards: no shard is every file", M.shard_files(["a.py", "b.py"], None), ["a.py", "b.py"])
check("shards: a shard past the files is empty", M.shard_files(["a.py"], "2/3"), [])

sys.exit(1 if FAILS else 0)
PY
eq "$?" 0 "pure: results, show, locate, config table, shard split"

# ---- CLI: `mutants` with python runs mutmut in a worktree; the stub replays the fixture for MUT_FIXTURE ----
# the stub: --version; run (copies the fixture's results, show and stdout into ./mutants, prints stdout, exits MUT_RC,
# or sleeps when MUT_HANG=1 so the budget kills it); results and show read ./mutants like mutmut does.
MUTSTUB="$T/mutstub.sh"
cat > "$MUTSTUB" <<'SH'
#!/bin/bash
echo "$(pwd -P) | $*" >> "$MECH_STUB_LOG"
case "$1" in
  --version) echo "mutmut, version 3.8.1"; exit 0 ;;
  run)
    if [[ -f pyproject.toml ]]; then { echo "PYPROJECT"; cat pyproject.toml; } >> "$MECH_STUB_LOG"; fi
    if [[ -n "${MUT_FIXTURE-}" ]]; then
      mkdir -p mutants; cp -r "$MECH_FX/$MUT_FIXTURE/." mutants/
      cat "$MECH_FX/$MUT_FIXTURE/stdout.txt" 2>/dev/null
    fi
    if [[ -n "${MUT_HANG-}" ]]; then sleep 30; fi
    exit "${MUT_RC:-0}" ;;
  results) cat mutants/results.txt 2>/dev/null ;;
  show) cat "mutants/show/$2.txt" 2>/dev/null || { echo "no such mutant: $2" >&2; exit 1; } ;;
esac
SH
chmod +x "$MUTSTUB"

PYBASE='def add(a, b):
    return a+b


def is_positive(n):
    return n>0


def mul(a, b):
    return a * b


def sub(a, b):
    return a - b
'
# mrepo <name> [pyproject text]: base has core.py with add and is_positive written differently; head is the fixture source.
# sets R (repo), B (base), H (head). Changed lines in the diff: add (line 2) and is_positive (line 6).
PYPROJ=$'[project]\nname = "calc"\nversion = "0.0.1"\n'
mrepo() {
  R="$T/$1"; mkdir -p "$R/src/calc" "$R/tests"; git -C "$R" init -q -b main
  printf '%s' "${2:-$PYPROJ}" > "$R/pyproject.toml"
  printf '%s' "$PYBASE" > "$R/src/calc/core.py"
  printf 'from calc.core import add\n\n\ndef test_add():\n    assert add(0, 0) == 0\n' > "$R/tests/test_core.py"
  git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@t commit -qm base; B=$(git -C "$R" rev-parse HEAD)
  cp "$FX/head/src/calc/core.py" "$R/src/calc/core.py"
  git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@t commit -qm head; H=$(git -C "$R" rev-parse HEAD)
}
# mut <args>: mutants subcommand with python on $R $B $H, the stub on MECH_TEST_STUB
mut() { MECH_TEST_STUB="$MUTSTUB" python3 -I "$MR" mutants --repo "$R" --base "$B" --head "$H" --stack python --test-paths 'tests/**' "$@"; }

# missed: 3 MISSED in the diff (add, two is_positive); sub is missed outside the diff and not reported; mul killed
mrepo missed
out=$(MUT_FIXTURE=missed mut); rc=$?
eq "$rc" 1 "python missed: exit 1"
eq "$(jq -r .checks.R3.status <<<"$out")" fail "python missed: R3 fail"
eq "$(jq -r '[.entries[] | select(.check=="R3")] | length' <<<"$out")" 3 "python missed: 3 entries, only the changed lines"
lacks "$(jq -r '[.entries[].file + ":" + (.line|tostring)] | join(" ")' <<<"$out")" "src/calc/core.py:14" "python missed: sub outside the diff not reported"
eq "$(jq -r '.entries[0].file' <<<"$out")" src/calc/core.py "python missed: file named"
eq "$(jq -r '.entries[0].line' <<<"$out")" 2 "python missed: line found in the head source (the add line)"
eq "$(jq -r '.entries[0].problem' <<<"$out")" "MISSED mutant src/calc/core.py:2: return a + b -> return a - b" "python missed: problem gives file, line and the mutation"
eq "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable "python missed: class agent-fixable"
eq "$(jq -r '.entries[0].severity' <<<"$out")" fail "python missed: severity fail"
eq "$(jq -r '.entries[0].forbidden' <<<"$out")" 'MISSED mutant `return a + b -> return a - b` in `src/calc/core.py`' "python missed: forbidden names the mutant"
has "$(jq -r '.entries[0].hint' <<<"$out")" "add an assert that fails for this mutant" "python missed: survived hint"
has "$(jq -r '[.entries[] | select(.line==6)][0].hint' <<<"$out")" "no test reaches this line" "python missed: no-tests hint"
eq "$(jq -r .summary <<<"$out")" "fail $H (3 fail, 0 confirm; ran: R3; skipped: R1 R2 R4)" "python missed: summary"
has "$(jq -r .checks.R3.note <<<"$out")" "3 missed in the diff" "python missed: note counts in-diff misses"
has "$(jq -r .checks.R3.note <<<"$out")" "1 missed outside the diff" "python missed: note counts outside misses"
has "$(cat "$MECH_STUB_LOG")" "results --all True" "python missed: reads every mutant's status"
has "$(cat "$MECH_STUB_LOG")" "show calc.core.x_add__mutmut_1" "python missed: shows each MISSED mutant for its location"
lacks "$(cat "$MECH_STUB_LOG")" "show calc.core.x_mul__mutmut_1" "python missed: killed mutants are not shown"
lacks "$(cat "$MECH_STUB_LOG")" "$R |" "python missed: mutmut runs in a worktree, not the caller checkout"
eq "$(git -C "$R" status --short | wc -l | tr -d ' ')" 0 "python missed: caller checkout untouched"
eq "$(git -C "$R" worktree list | wc -l | tr -d ' ')" 1 "python missed: no worktree left behind"
eq "$(jq -c '.checks.R3.timing | keys' <<<"$out")" '["wall_s"]' "python missed: timing has wall time only (mutmut supplies no phase durations)"

# the config mutmut reads is written into the worktree: source and the changed files only
has "$(cat "$MECH_STUB_LOG")" 'only_mutate = ["src/calc/core.py"]' "python config: only_mutate is the changed production file"
has "$(cat "$MECH_STUB_LOG")" 'source_paths = ["src"]' "python config: source_paths is the top-level dir of the changed files"

# caught: every mutant killed
mrepo caught
out=$(MUT_FIXTURE=caught mut); rc=$?
eq "$rc" 0 "python caught: exit 0"
eq "$(jq -r .checks.R3.status <<<"$out")" pass "python caught: R3 pass"
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 0 confirm; ran: R3; skipped: R1 R2 R4)" "python caught: summary names ran and skipped"

# partial: budget kills the run, 4 of 5 tested, none missed: partial, not blocking, names tested/total
mrepo partial
SECONDS=0
out=$(MUT_FIXTURE=partial MUT_HANG=1 mut --mutation-budget 0.05); rc=$?
eq "$rc" 0 "python partial: exit 0 (does not block)"
eq "$(jq -r .checks.R3.status <<<"$out")" partial "python partial: R3 partial"
has "$(jq -r .checks.R3.note <<<"$out")" "4/5 tested" "python partial: note tested/total"
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 1 confirm; ran: R3; partial: R3 (4/5); skipped: R1 R2 R4)" "python partial: summary"
eq "$(jq -r '[.entries[] | select(.severity=="confirm")][0].problem' <<<"$out")" "R3 partial: 1/5 mutants untested at budget" "python partial: confirm names untested"
[[ $SECONDS -lt 15 ]] && ok "python partial: budget kill is prompt" || fail "python partial: budget kill took ${SECONDS}s"

# not installed: n/a (env), never a pass
mrepo nocmd
out=$(env -u MECH_TEST_STUB python3 -I "$MR" mutants --repo "$R" --base "$B" --head "$H" --stack python --test-paths 'tests/**' --mutants-cmd "ek-no-such-mutmut"); rc=$?
eq "$rc" 0 "python not installed: exit 0 (n/a is not a failure)"
eq "$(jq -r .checks.R3.status <<<"$out")" n/a "python not installed: R3 n/a"
has "$(jq -r .checks.R3.note <<<"$out")" "(env)" "python not installed: note says env"
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 0 confirm; ran: none; skipped: R1 R2 R4; n/a: R3)" "python not installed: summary names n/a"

# baseline fails at head: fail, agent-fixable, mutants not run
mrepo baseline
out=$(MUT_FIXTURE=broken MUT_RC=1 mut); rc=$?
eq "$rc" 1 "python baseline fails: exit 1"
eq "$(jq -r .checks.R3.status <<<"$out")" fail "python baseline fails: R3 fail"
has "$(jq -r '.entries[0].problem' <<<"$out")" "baseline tests fail at head" "python baseline fails: names the baseline"
eq "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable "python baseline fails: agent-fixable"

# stops early (no test covers any mutant): the untested changed mutants are no tests, so MISSED in the diff
mrepo uncovered
out=$(MUT_FIXTURE=uncovered MUT_RC=1 mut); rc=$?
eq "$rc" 1 "python uncovered: exit 1 (no test reaches the changed code)"
eq "$(jq -r '[.entries[] | select(.check=="R3")] | length' <<<"$out")" 3 "python uncovered: changed mutants counted as missed"
eq "$(jq -r .checks.R3.status <<<"$out")" fail "python uncovered: R3 fail"

# zero mutants (the changed file has nothing mutmut can mutate): pass, named as zero
mrepo zero
B=$H; printf '"""only a docstring."""\n' > "$R/src/calc/empty.py"; git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@t commit -qm empty; H=$(git -C "$R" rev-parse HEAD)
out=$(MUT_FIXTURE=zero MUT_RC=1 mut); rc=$?
eq "$rc" 0 "python zero mutants: exit 0"
eq "$(jq -r .checks.R3.status <<<"$out")" pass "python zero mutants: R3 pass"
has "$(jq -r .checks.R3.note <<<"$out")" "0 mutants in the diff" "python zero mutants: note"

# no production file changed: skipped, mutmut not run
mrepo docs
B=$H; printf 'notes\n' > "$R/README.md"; git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@t commit -qm docs; H=$(git -C "$R" rev-parse HEAD)
: > "$MECH_STUB_LOG"
out=$(MUT_FIXTURE=missed mut); rc=$?
eq "$rc" 0 "python no prod change: exit 0"
eq "$(jq -r .checks.R3.status <<<"$out")" skipped "python no prod change: R3 skipped"
eq "$(wc -l < "$MECH_STUB_LOG" | tr -d ' ')" 0 "python no prod change: mutmut not invoked"

# the repo already configures mutmut: R3 cannot set only_mutate, so n/a (env), never a silent full-repo run
mrepo ownconfig '[tool.mutmut]
source_paths = ["src"]
'
: > "$MECH_STUB_LOG"
out=$(MUT_FIXTURE=caught mut); rc=$?
eq "$(jq -r .checks.R3.status <<<"$out")" n/a "python own [tool.mutmut]: R3 n/a"
has "$(jq -r .checks.R3.note <<<"$out")" "[tool.mutmut]" "python own [tool.mutmut]: note names the table"
eq "$(wc -l < "$MECH_STUB_LOG" | tr -d ' ')" 0 "python own [tool.mutmut]: mutmut not invoked"

# shards: each shard mutates its own share of the changed production files
R="$T/shards"; mkdir -p "$R/src"; git -C "$R" init -q -b main
printf 'def a():\n    return 1\n' > "$R/src/a.py"; printf 'def b():\n    return 2\n' > "$R/src/b.py"
git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@t commit -qm base; B=$(git -C "$R" rev-parse HEAD)
printf 'def a():\n    return 3\n' > "$R/src/a.py"; printf 'def b():\n    return 4\n' > "$R/src/b.py"
git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@t commit -qm head; H=$(git -C "$R" rev-parse HEAD)
: > "$MECH_STUB_LOG"
out=$(MUT_FIXTURE=caught mut --shard 1/2); rc=$?
has "$(cat "$MECH_STUB_LOG")" 'only_mutate = ["src/b.py"]' "python shard 1/2: mutates the second changed file only"
lacks "$(cat "$MECH_STUB_LOG")" '"src/a.py"' "python shard 1/2: the first file is not in this shard"
: > "$MECH_STUB_LOG"
out=$(MUT_FIXTURE=caught mut --shard 2/3); rc=$?
eq "$(jq -r .checks.R3.note <<<"$out")" "0 mutants in the diff (no changed production file in this shard)" "python shard past the files: named empty"
eq "$(wc -l < "$MECH_STUB_LOG" | tr -d ' ')" 0 "python shard past the files: mutmut not invoked"

# ids: stable when lines move, the entry's line follows the code
mrepo ids
out1=$(MUT_FIXTURE=missed mut)
printf '\n' | cat - "$R/src/calc/core.py" > "$T/moved.py" && cp "$T/moved.py" "$R/src/calc/core.py"
git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@t commit -qm moved; H2=$(git -C "$R" rev-parse HEAD)
out2=$(MUT_FIXTURE=missed MECH_TEST_STUB="$MUTSTUB" python3 -I "$MR" mutants --repo "$R" --base "$B" --head "$H2" --stack python --test-paths 'tests/**')
eq "$(jq -r '[.entries[].id] | sort | join(" ")' <<<"$out1")" "$(jq -r '[.entries[].id] | sort | join(" ")' <<<"$out2")" "python ids: stable when lines move"
eq "$(jq -r '.entries[0].line' <<<"$out2")" 3 "python ids: the entry line follows the code (add moved to line 3)"

# plan: a python production change runs the mutants job over the shard matrix; a rust stack does not run it for .py files
mrepo planpy
out=$(python3 -I "$MR" plan --repo "$R" --base "$B" --head "$H" --stack python --test-paths 'tests/**' --shards 4)
eq "$(jq -c '{run,count,shards}' <<<"$out")" '{"run":true,"count":4,"shards":[0,1,2,3]}' "python plan: production change runs 4 shards"
mrepo planrust
out=$(python3 -I "$MR" plan --repo "$R" --base "$B" --head "$H" --stack rust --test-paths 'tests/**' --shards 4)
eq "$(jq -c '{run,count}' <<<"$out")" '{"run":false,"count":1}' "rust stack on .py files: not run (ek itself stays on rust)"


done_tests
