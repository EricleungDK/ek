#!/bin/bash
# Python R1 red-first and R4 determinism: pytest/unittest outcome mapping, named-test argv, and `red` on temp git repos.
# The test runner is stubbed (MECH_TEST_STUB) with pytest-shaped output; the stub reads ./outcomes in its cwd.
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

# fake pytest: pytest-shaped output (captured from pytest 9.2.0) for the outcome of the test named last in argv
STUB="$T/pystub.sh"
cat > "$STUB" <<'SH'
#!/bin/bash
last="${*: -1}"
name="${last##*::}"; name="${name##*.}"
echo "$(pwd -P) | $*" >> "$MECH_STUB_LOG"
f=outcomes; [[ -f $f ]] || f=tests/outcomes.base  # R1's checkout: base code + the PR's test files
o=$(awk -v n="$name" '$1 == n { print $2 }' "$f" 2>/dev/null)
case "${o:-pass}" in
  pass)  printf '.\n1 passed in 0.01s\n'; exit 0 ;;
  fail)  printf 'FAILED tests/a.py::%s - assert 1 == 2\n1 failed in 0.01s\n' "$name"; exit 1 ;;
  build) printf 'ERROR tests/a.py\n1 error in 0.01s\n'; exit 4 ;;
  none)  printf 'no tests ran in 0.00s\n'; exit 4 ;;
  error) printf 'INTERNALERROR> boom\n'; exit 3 ;;
  env)   printf '/usr/bin/python3: No module named pytest\n'; exit 1 ;;
  flaky) n=$(( $(cat "$MECH_STUB_STATE/$name" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$MECH_STUB_STATE/$name"
         if (( n % 2 )); then printf 'FAILED tests/a.py::%s - assert 1 == 2\n1 failed in 0.01s\n' "$name"; exit 1; fi
         printf '1 passed in 0.01s\n'; exit 0 ;;
esac
SH
chmod +x "$STUB"

# red <repo> <base> <head> [args]: red subcommand with the stub, python config
red() { local r="$1" b="$2" h="$3"; shift 3; MECH_TEST_STUB="$STUB" python3 -I "$MR" red --repo "$r" --base "$b" --head "$h" --stack python --test-paths 'tests/**' "$@"; }

# agent_repo <name>: base (adds); red commit adds test_fresh (outcome RED_OUT, default fail); head fixes prod.
# env: RED_OUT, HEAD_OUT (outcome of test_fresh at head, default pass), RED_PROD=1, RED_NOTEST=1, RED_UNPARSE=1 (red adds a broken test)
# sets R (repo), B (base), RED (first red commit), H (head)
agent_repo() {
  R=$(mkrepo "$1"); local red_out="${RED_OUT-fail}" head_out="${HEAD_OUT-pass}"
  put "$R" src/calc.py <<'EOF'
def add(a, b):
    return a + b
EOF
  put "$R" tests/test_a.py <<'EOF'
from calc import add


def test_adds():
    assert add(2, 2) == 4
EOF
  B=$(commit "$R" base)
  if [[ -n "${RED_NOTEST-}" ]]; then
    echo docs > "$R/README.md"
    printf 'test_adds pass\n' > "$R/outcomes"
  else
    put "$R" tests/test_a.py <<'EOF'
from calc import add


def test_adds():
    assert add(2, 2) == 4


def test_fresh():
    assert add(1, 2) == 3
EOF
    [[ -n "${RED_UNPARSE-}" ]] && put "$R" tests/test_a.py <<'EOF'
from calc import add


def test_adds(:
    assert add(2, 2) == 4
EOF
    printf 'test_fresh %s\ntest_adds pass\n' "$red_out" > "$R/outcomes"
    cp "$R/outcomes" "$R/tests/outcomes.base"
  fi
  if [[ -n "${RED_PROD-}" ]]; then printf '# red\n' >> "$R/src/calc.py"; fi
  RED=$(commit "$R" "${RED_SUBJECT:-test(red): fresh}")
  printf 'test_fresh %s\ntest_adds pass\n' "$head_out" > "$R/outcomes"
  put "$R" src/calc.py <<'EOF'
def add(a, b):
    return a + b  # fixed
EOF
  H=$(commit "$R" "feat: fix")
}

# ---- adapter unit: outcome vocabulary (pytest and unittest shapes), argv (pure) ----
python3 -I - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
from mech_review.stack import PythonAdapter

A = PythonAdapter()
FAILS = 0


def check(name, got, want):
    global FAILS
    if got == want:
        print(f"  ok   {name}")
    else:
        FAILS += 1
        print(f"  FAIL {name}\n       want: {want!r}\n       got:  {got!r}")


check("outcome: pytest pass", A.outcome(0, "1 passed in 0.01s"), "pass")
check("outcome: pytest fail", A.outcome(1, "FAILED tests/a.py::t - assert 1 == 2\n1 failed in 0.01s"), "fail")
check("outcome: pytest no tests ran (also a nodeid not found) is none", A.outcome(4, "no tests ran in 0.00s"), "none")
check("outcome: deselected only is none", A.outcome(5, "5 deselected in 0.01s"), "none")
check("outcome: only skipped is none", A.outcome(0, "1 skipped in 0.01s"), "none")
check("outcome: collection error is build", A.outcome(4, "ERROR tests/a.py\n1 error in 0.01s"), "build")
check("outcome: interrupted by a collection error is build",
      A.outcome(2, "Interrupted: 1 error during collection"), "build")
check("outcome: pytest missing is env", A.outcome(1, "/usr/bin/python3: No module named pytest"), "env")
check("outcome: no executable is env", A.outcome(None, "python3: not found"), "env")
check("outcome: timeout", A.outcome("timeout", ""), "timeout")
check("outcome: internal error is error", A.outcome(3, "INTERNALERROR> boom"), "error")
check("outcome: no output at all is error", A.outcome(0, ""), "error")
check("outcome: unittest pass", A.outcome(0, "Ran 1 test in 0.000s\n\nOK"), "pass")
check("outcome: unittest skipped only is none", A.outcome(0, "Ran 1 test in 0.000s\n\nOK (skipped=1)"), "none")
check("outcome: unittest zero tests is none", A.outcome(0, "Ran 0 tests in 0.000s\n\nOK"), "none")
check("outcome: unittest failure is fail", A.outcome(1, "FAILED (failures=1)"), "fail")
check("outcome: unittest import failure is build",
      A.outcome(1, "ERROR: test_ie (unittest.loader._FailedTest.test_ie)\nImportError: Failed to import test module: test_ie"),
      "build")
check("outcome: unittest name not found is error",
      A.outcome(1, "ERROR: nope (unittest.loader._FailedTest.nope)\nFAILED (errors=1)"), "error")

check("argv: pytest runs one nodeid, class and all",
      A.test_argv("python3 -m pytest", "tests/test_a.py", "TestCalc::test_add"),
      ["python3", "-m", "pytest", "-q", "tests/test_a.py::TestCalc::test_add"])
check("argv: pytest module fn", A.test_argv("python3 -m pytest", "tests/sub/test_b.py", "test_x"),
      ["python3", "-m", "pytest", "-q", "tests/sub/test_b.py::test_x"])
check("argv: unittest command gets the dotted name",
      A.test_argv("python3 -m unittest", "tests/test_a.py", "CalcCase::test_add"),
      ["python3", "-m", "unittest", "tests.test_a.CalcCase.test_add"])

sys.exit(1 if FAILS else 0)
PY
eq "$?" 0 "adapter unit: pytest and unittest outcomes, named-test argv"

# ---- R1 red-first on python: the red commit's new test fails there, passes at head ----
agent_repo ok
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 0 "python red fails, head passes: exit 0"
eq "$(jq -r .checks.R1.status <<<"$out")" pass "python R1 pass"
eq "$(jq -r .checks.R4.status <<<"$out")" pass "python R4 pass"
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 0 confirm; ran: R1 R4; skipped: R2 R3)" "python: summary names ran and skipped"
has "$(cat "$MECH_STUB_LOG")" "-m pytest -q tests/test_a.py::test_fresh" "python: pytest runs the new test by nodeid"

RED_OUT=pass agent_repo passes
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 1 "python: no new test fails on the base's code: exit 1"
has "$(jq -r '.entries[0].problem' <<<"$out")" "no new or changed test fails without this PR's production change: \`test_fresh\`" "python red-pass names the test"
eq "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable "python red-pass class agent-fixable"
eq "$(jq -r '.entries[0].check' <<<"$out")" R1 "python red-pass check R1"

RED_OUT=build agent_repo nobuild
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 0 "python compile-red counts as red, exit 0"
eq "$(jq -r '.entries | length' <<<"$out")" 0 "python compile-red: no entry, no reviewer step"
has "$(jq -r .checks.R1.note <<<"$out")" "(1 compile-red)" "python compile-red named in the note"

RED_PROD=1 agent_repo prodred
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 0 "python: tests and production in one commit: exit 0 (order does not matter)"
eq "$(jq -r .checks.R1.status <<<"$out")" pass "python: tests with production: R1 pass"

RED_NOTEST=1 agent_repo notest
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 1 "python red commit with no new test: exit 1"

R=$(mkrepo nonagent)
put "$R" src/calc.py <<'EOF'
def add(a, b):
    return a + b
EOF
put "$R" tests/test_a.py <<'EOF'
def test_adds():
    assert True
EOF
B=$(commit "$R" base)
printf 'def add(a, b):\n    return a + b  # x\n' > "$R/src/calc.py"; H=$(commit "$R" feat)
out=$(red "$R" "$B" "$H" --head-branch feature/x); rc=$?
eq "$(jq -r .checks.R1.status <<<"$out")" skipped "python R1 skipped on a non-agent branch"

# ---- R1 and R4 n/a without the toolchain: never a pass ----
agent_repo noexe
out=$(env -u MECH_TEST_STUB python3 -I "$MR" red --repo "$R" --base "$B" --head "$H" --stack python --test-paths 'tests/**' --head-branch agent/x --test-cmd "ek-no-such-python -m pytest"); rc=$?
eq "$(jq -r .checks.R1.status <<<"$out")" n/a "python missing toolchain: R1 n/a"
eq "$(jq -r .checks.R4.status <<<"$out")" n/a "python missing toolchain: R4 n/a"
has "$(jq -r .summary <<<"$out")" "n/a: R1 R4" "python missing toolchain: summary names n/a"
lacks "$(jq -r .summary <<<"$out")" "all pass" "python missing toolchain: never all pass"

# ---- R4 determinism on python ----
HEAD_OUT=flaky agent_repo flaky
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 1 "python flaky test at head: exit 1"
eq "$(jq -r '[.entries[] | select(.check=="R4")][0].class' <<<"$out")" agent-fixable "python flaky class agent-fixable"
has "$(jq -r '[.entries[] | select(.check=="R4")][0].problem' <<<"$out")" "test \`test_fresh\` failed" "python flaky names the test"
has "$(jq -r '[.entries[] | select(.check=="R4")][0].id' <<<"$out")" "R4-" "python flaky id"

HEAD_OUT=none agent_repo none
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 1 "python test that does not run at head: exit 1"
has "$(jq -r '[.entries[] | select(.check=="R4")][0].problem' <<<"$out")" "did not run at head" "python not-run problem"

HEAD_OUT=error agent_repo broken
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 1 "python test that cannot run at head: exit 1"
has "$(jq -r '[.entries[] | select(.check=="R4")][0].problem' <<<"$out")" "cannot run at head" "python cannot-run problem"

RED_UNPARSE=1 agent_repo unparse
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 1 "python unparseable test file at head: exit 1, not a crash"
has "$(jq -r '[.entries[] | select(.check=="R4")][0].problem' <<<"$out")" "does not parse" "python unparseable test file: R4 says does not parse"

# ---- argv: default runner is pytest; unittest command gets dotted names; the stub replaces only the executable ----
agent_repo argv
: > "$MECH_STUB_LOG"
red "$R" "$B" "$H" --head-branch agent/x >/dev/null
has "$(cat "$MECH_STUB_LOG")" "-m pytest -q tests/test_a.py::test_fresh" "argv: default command is pytest, one nodeid (stub replaces argv[0])"
: > "$MECH_STUB_LOG"
MECH_TEST_STUB="$STUB" python3 -I "$MR" red --repo "$R" --base "$B" --head "$H" --stack python --test-paths 'tests/**' --head-branch agent/x --test-cmd "python3 -m unittest" >/dev/null
has "$(cat "$MECH_STUB_LOG")" "tests.test_a.test_fresh" "argv: unittest command runs the dotted name"

# ---- all: R1, R2 and R4 on python in one run ----
agent_repo allrun
out=$(MECH_TEST_STUB="$STUB" python3 -I "$MR" all --repo "$R" --base "$B" --head "$H" --stack python --test-paths 'tests/**' --head-branch agent/x); rc=$?
eq "$rc" 0 "python all: exit 0"
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 0 confirm; ran: R1 R2 R4; skipped: R3)" "python all: runs R1 R2 R4"

# ---- project-dir and manifests on python: R1/R4 run in the crate dir with crate-relative ids; paths stay repo-root ----
# pd_repo <name>: pkg/ is the crate (pyproject, calc, tests); base adds test_adds, red adds test_fresh, head fixes calc.
# env: RED_OUT, HEAD_OUT as agent_repo. sets R, B, RED, H
pd_repo() {
  R=$(mkrepo "$1"); local red_out="${RED_OUT-fail}" head_out="${HEAD_OUT-pass}"
  put "$R" pkg/pyproject.toml <<'EOF'
[project]
name = "calc"
version = "0.0.1"
EOF
  put "$R" pkg/calc/core.py <<'EOF'
def add(a, b):
    return a + b
EOF
  put "$R" pkg/tests/test_a.py <<'EOF'
from calc.core import add


def test_adds():
    assert add(2, 2) == 4
EOF
  put "$R" other/x.py <<'EOF'
X = 1
EOF
  B=$(commit "$R" base)
  put "$R" pkg/tests/test_a.py <<'EOF'
from calc.core import add


def test_adds():
    assert add(2, 2) == 4


def test_fresh():
    assert add(1, 2) == 3
EOF
  printf 'test_fresh %s\ntest_adds pass\n' "$red_out" > "$R/pkg/outcomes"
  cp "$R/pkg/outcomes" "$R/pkg/tests/outcomes.base"
  RED=$(commit "$R" "test(red): fresh")
  printf 'test_fresh %s\ntest_adds pass\n' "$head_out" > "$R/pkg/outcomes"
  put "$R" pkg/calc/core.py <<'EOF'
def add(a, b):
    return a + b  # fixed
EOF
  H=$(commit "$R" "feat: fix")
}
pd_red() { local r="$1" b="$2" h="$3"; shift 3; MECH_TEST_STUB="$STUB" python3 -I "$MR" red --repo "$r" --base "$b" --head "$h" --stack python --test-paths 'pkg/tests/**' "$@"; }

pd_repo pd1
: > "$MECH_STUB_LOG"
out=$(pd_red "$R" "$B" "$H" --project-dir pkg --head-branch agent/x); rc=$?
eq "$rc" 0 "project-dir python: red fails, head passes: exit 0"
eq "$(jq -r .checks.R1.status <<<"$out")" pass "project-dir python: R1 pass"
eq "$(jq -r .checks.R4.status <<<"$out")" pass "project-dir python: R4 pass"
has "$(cat "$MECH_STUB_LOG")" "/pkg |" "project-dir python: the runner starts in the crate dir"
has "$(cat "$MECH_STUB_LOG")" "-q tests/test_a.py::test_fresh" "project-dir python: nodeid is crate-relative"
lacks "$(cat "$MECH_STUB_LOG")" "pkg/tests/test_a.py::" "project-dir python: no repo-root nodeid reaches pytest"

RED_OUT=pass pd_repo pd2
out=$(pd_red "$R" "$B" "$H" --project-dir pkg --head-branch agent/x); rc=$?
eq "$rc" 1 "project-dir python: red passes at the red commit: exit 1"
eq "$(jq -r '.entries[0].file' <<<"$out")" pkg/tests/test_a.py "project-dir python: entry file is repo-root"

pd_repo pd3
out=$(pd_red "$R" "$B" "$H" --project-dir nosuch --head-branch agent/x); rc=$?
has "$(jq -r '[.entries[].problem] | join(" ")' <<<"$out")" "project dir nosuch not in this commit" "project-dir python: missing dir named"

# no manifest where the runner ran: the cannot-run hint names project-dir, for python (never Cargo.toml)
HEAD_OUT=error agent_repo nomanifest
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$rc" 1 "python: test cannot run at head: exit 1"
has "$(jq -r '[.entries[] | select(.check=="R4")][0].hint' <<<"$out")" "no pyproject.toml, setup.py or setup.cfg in .: set project-dir" "python: no-manifest hint names the manifest files and project-dir"
lacks "$(cat <<<"$out")" "Cargo" "python: no Cargo.toml anywhere in the output"

pd_repo pd4
out=$(HEAD_OUT=error pd_red "$R" "$B" "$H" --project-dir pkg --head-branch agent/x); rc=$?
lacks "$(jq -r '[.entries[].hint] | join(" ")' <<<"$out")" "set project-dir" "python: manifest present in project-dir: no project-dir hint"

# pytest not installed: n/a names the test deps and setup-command, never the toolchain name
RED_OUT=env HEAD_OUT=env agent_repo envpy
out=$(red "$R" "$B" "$H" --head-branch agent/x); rc=$?
eq "$(jq -r .checks.R1.status <<<"$out")" n/a "python pytest missing: R1 n/a"
has "$(jq -r .checks.R1.note <<<"$out")" "pytest not installed (env)" "python pytest missing: note names pytest"
has "$(jq -r .checks.R1.note <<<"$out")" "setup-command" "python pytest missing: note names setup-command"
lacks "$(jq -r .checks.R1.note <<<"$out")" "\`python3\` not found" "python pytest missing: not a missing executable"

done_tests
