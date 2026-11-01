#!/bin/bash
# Python stack (#21): adapter detection, R2 test-diff guard on temp git repos mirroring the Rust cases in mech-review.test.sh.
source "$(dirname "$0")/lib.sh"
MR="$ROOT/scripts/mech-review.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# mkrepo <name>: fresh git repo on main, prints path
mkrepo() { local r="$T/$1"; mkdir -p "$r"; git -C "$r" init -q -b main; echo "$r"; }
# put <repo> <path>: write stdin to file (mkdir -p)
put() { mkdir -p "$(dirname "$1/$2")"; cat > "$1/$2"; }
# commit <repo> <msg>: stage all, commit, print sha
commit() { git -C "$1" add -A; git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "$2"; git -C "$1" rev-parse HEAD; }
# mr <repo> <base> <head> [extra args]: r2 with the python stack
mr() { local r="$1" b="$2" h="$3"; shift 3; python3 -I "$MR" r2 --repo "$r" --base "$b" --head "$h" --stack python --test-paths 'tests/**' "$@"; }
# sid <text>: the id R2 gives an entry with this file+key (check R2)
sid() { printf 'R2-%s' "$(printf 'R2%s' "$1" | sha1sum | cut -c1-8)"; }

# ---- adapter unit: detection, test fns, assertions, markers, parse errors (pure) ----
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


check("classify: test-path .py is test", A.classify("tests/test_a.py", ["tests/**"]), "test")
check("classify: other .py is prod", A.classify("src/calc.py", ["tests/**"]), "prod")
check("classify: test_*.py outside the globs is prod (globs decide)", A.classify("pkg/test_x.py", ["tests/**"]), "prod")
check("classify: non-python is not this stack", A.classify("README.md", ["tests/**"]), None)
check("classify: rust file is not python", A.classify("src/lib.rs", ["tests/**"]), None)
check("default test cmd is pytest", A.default_test_cmd, "python3 -m pytest")

SRC = """import unittest
import pytest


def test_top():
    assert 1 == 1


class TestStyle:
    def test_m(self):
        assert f() == 2

    def helper(self):
        assert True


class Base(unittest.TestCase):
    def test_u(self):
        self.assertEqual(f(), 3)


class Child(Base):
    def testOld(self):
        self.assertTrue(f())


@pytest.mark.skip(reason="todo")
def test_skipped():
    assert f()


def not_a_test():
    assert False
"""
fns = A.test_fns(SRC)
check("test_fns: module fn, pytest class method, unittest method, inherited TestCase method",
      sorted(f.name for f in fns), sorted(["test_top", "TestStyle::test_m", "Base::test_u", "Child::testOld", "test_skipped"]))
check("test_fns: line is the def line", next(f.line for f in fns if f.name == "test_top"), 5)
check("test_fns: decorator skip is an ignore marker",
      next(f.markers for f in fns if f.name == "test_skipped"), ["ignore"])
check("test_fns: plain test has no marker", next(f.markers for f in fns if f.name == "test_top"), [])

asserts = A.assertions(SRC)
by_fn = {}
for a in asserts:
    by_fn.setdefault(a.fn, []).append(a)
check("assertions: bare assert == is eq with operands",
      [(a.kind, a.left, a.right) for a in by_fn["test_top"]], [("eq", "1", "1")])
check("assertions: self.assertEqual is eq",
      [(a.kind, a.left, a.right) for a in by_fn["Base::test_u"]], [("eq", "f()", "3")])
check("assertions: self.assertTrue is other",
      [a.kind for a in by_fn["Child::testOld"]], ["other"])
check("assertions: helper method of a TestCase-style class is in scope, owned by the helper, fn None",
      [(a.fn, a.scope, a.owner) for a in asserts if a.owner == "TestStyle::helper"], [(None, True, "TestStyle::helper")])
check("assertions: module-level function outside a test is out of scope",
      [(a.fn, a.scope) for a in asserts if a.owner == "not_a_test"], [(None, False)])
check("assertions: text is the whole assert, whitespace-normalized",
      by_fn["test_top"][0].text, "assert 1 == 1")
check("assertions: eq operands are whitespace-free canonical text",
      [(a.left, a.right) for a in by_fn["TestStyle::test_m"]], [("f()", "2")])

check("assertions: != is ne", [a.kind for a in A.assertions("def test_x():\n    assert a != b\n")], ["ne"])
check("assertions: pytest.raises counts as an assertion (other)",
      [a.kind for a in A.assertions("def test_x():\n    with pytest.raises(ValueError):\n        f()\n")], ["other"])
check("assertions: self.assertNotEqual is ne",
      [a.kind for a in A.assertions("class T(unittest.TestCase):\n    def test_x(self):\n        self.assertNotEqual(a, b)\n")], ["ne"])

check("parse_error: syntax error gives its line",
      (A.parse_error("x = 1\ndef f(:\n    pass\n") or (None,))[0], 2)
check("parse_error: valid source is None", A.parse_error("def f():\n    return 1\n"), None)

calls = A.calls("def test_a():\n    check(1)\n    self.helper()\n    obj.method()\n")
check("calls: plain and self calls, not other receivers", sorted(calls["test_a"]), ["check", "helper"])

bodies = A.test_bodies("def test_adds():\n    assert add(1, 2) == 3\n")
check("test_bodies: only test fns, keyed by name", sorted(bodies), ["test_adds"])
check("test_bodies: whitespace and comments do not change the body",
      A.test_bodies("def test_adds():\n    assert add(1,2)==3  # note\n")["test_adds"][1], bodies["test_adds"][1])
check("test_bodies: a changed assert changes the body",
      A.test_bodies("def test_adds():\n    assert add(1, 2) == 4\n")["test_adds"][1] != bodies["test_adds"][1], True)

sups = A.suppressions("import os  # noqa\nx = 1  # noqa: E501 — url literal\ny = 2  # type: ignore\n"
                      "z = 3  # type: ignore[attr-defined]  # stub gap\n")
check("suppressions: noqa and type: ignore found with line and reason flag",
      [(s.line, s.kind, s.reason) for s in sups],
      [(1, "noqa", False), (2, "noqa", True), (3, "type: ignore", False), (4, "type: ignore", True)])
check("suppressions: a noqa inside a string is not one",
      A.suppressions("s = '# noqa'\n"), [])

sys.exit(1 if FAILS else 0)
PY
eq "$?" 0 "adapter unit: detection, test fns, assertions, calls, bodies, suppressions, parse errors"

# ---- R2 slice 1: envelope and clean change on python ----
R=$(mkrepo p1)
put "$R" src/calc.py <<'EOF'
def add(a, b):
    return a + b
EOF
put "$R" tests/test_calc.py <<'EOF'
from calc import add


def test_adds():
    assert add(1, 1) == 2
EOF
B=$(commit "$R" base)
put "$R" src/calc.py <<'EOF'
def add(a, b):
    return a + b


def sub(a, b):
    return a - b
EOF
H=$(commit "$R" feat)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "python clean change exit 0"
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 0 confirm; ran: R2; skipped: R1 R3 R4)" "python clean summary names skipped checks"
eq "$(jq -r .checks.R2.status <<<"$out")" pass "python R2 pass"
out=$(python3 -I "$MR" r2 --repo "$R" --base "$B" --head "$H" --stack python 2>&1); rc=$?
eq "$rc" 0 "python: default test paths still run"

# ---- R2 removed test fn (module fn, class method, unittest method) ----
R=$(mkrepo p2)
put "$R" tests/test_a.py <<'EOF'
def test_adds():
    assert add(1, 1) == 2


def test_keeps():
    assert add(2, 2) == 4
EOF
B=$(commit "$R" base)
put "$R" tests/test_a.py <<'EOF'
def test_adds():
    assert add(1, 1) == 2
EOF
H=$(commit "$R" drop-keeps)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "python removed test fn exit 1"
eq "$(jq -r '.entries|length' <<<"$out")" 1 "python removed fn: one entry"
eq "$(jq -r '.entries[0].check' <<<"$out")" R2 "python removed entry R2"
eq "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable "python removed class agent-fixable"
eq "$(jq -r '.entries[0].severity' <<<"$out")" fail "python removed severity fail"
eq "$(jq -r '.entries[0].file' <<<"$out")" tests/test_a.py "python removed file"
eq "$(jq -r '.entries[0].line' <<<"$out")" 5 "python removed line = base def line of the removed fn"
has "$(jq -r '.entries[0].problem' <<<"$out")" '`test_keeps`' "python removed problem names the fn"
eq "$(jq -r '.entries[0].id' <<<"$out")" "$(sid 'tests/test_a.pytest_keeps')" "python removed id keyed by file + fn"

R=$(mkrepo p2rename)
put "$R" tests/test_a.py <<'EOF'
def test_old_name():
    assert add(2, 2) == 4
EOF
B=$(commit "$R" base)
put "$R" tests/test_a.py <<'EOF'
def test_new_name():
    assert add(2, 2) == 4
EOF
H=$(commit "$R" rename)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "python rename with the same asserts is not a removal"

R=$(mkrepo p2class)
put "$R" tests/test_a.py <<'EOF'
class TestCalc:
    def test_add(self):
        assert add(1, 1) == 2

    def test_mul(self):
        assert mul(2, 2) == 4
EOF
B=$(commit "$R" base)
put "$R" tests/test_a.py <<'EOF'
class TestCalc:
    def test_add(self):
        assert add(1, 1) == 2
EOF
H=$(commit "$R" drop-mul)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "python removed class method exit 1"
has "$(jq -r '.entries[0].problem' <<<"$out")" '`TestCalc::test_mul`' "class method problem uses Class::method"
eq "$(jq -r '.entries[0].id' <<<"$out")" "$(sid 'tests/test_a.pyTestCalc::test_mul')" "class method id keyed by Class::method"

R=$(mkrepo p2unit)
put "$R" tests/test_a.py <<'EOF'
import unittest


class CalcCase(unittest.TestCase):
    def test_add(self):
        self.assertEqual(add(1, 1), 2)

    def test_sub(self):
        self.assertEqual(sub(2, 1), 1)
EOF
B=$(commit "$R" base)
put "$R" tests/test_a.py <<'EOF'
import unittest


class CalcCase(unittest.TestCase):
    def test_add(self):
        self.assertEqual(add(1, 1), 2)
EOF
H=$(commit "$R" drop-sub)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "python removed unittest method exit 1"
has "$(jq -r '.entries[0].problem' <<<"$out")" '`CalcCase::test_sub`' "unittest method problem uses Class::method"

# ---- R2 skip markers and self.skipTest ----
skip_case() {  # skip_case <name> <head body (test fn named test_x)>
  local R B H out rc
  R=$(mkrepo "skip-$1")
  put "$R" tests/test_a.py <<'EOF'
import unittest
import pytest


def test_x():
    assert add(1, 1) == 2
EOF
  B=$(commit "$R" base)
  put "$R" tests/test_a.py < "$2"
  H=$(commit "$R" skip)
  out=$(mr "$R" "$B" "$H"); rc=$?
  eq "$rc" 1 "python skip marker $1: exit 1"
  has "$(jq -r '.entries[0].problem' <<<"$out")" '`test_x`' "python skip marker $1: problem names the test"
  eq "$(jq -r '.entries[0].severity' <<<"$out")" fail "python skip marker $1: severity fail"
  eq "$(jq -r '.entries[0].id' <<<"$out")" "$(sid 'tests/test_a.pyignore:test_x')" "python skip marker $1: id keyed by ignore:fn"
}
cat > "$T/h-pytest-skip" <<'EOF'
import unittest
import pytest


@pytest.mark.skip(reason="todo")
def test_x():
    assert add(1, 1) == 2
EOF
cat > "$T/h-xfail" <<'EOF'
import unittest
import pytest


@pytest.mark.xfail
def test_x():
    assert add(1, 1) == 2
EOF
cat > "$T/h-unittest-skip" <<'EOF'
import unittest
import pytest


@unittest.skip("flaky")
def test_x():
    assert add(1, 1) == 2
EOF
cat > "$T/h-skipif" <<'EOF'
import unittest
import pytest


@pytest.mark.skipif(True, reason="ci")
def test_x():
    assert add(1, 1) == 2
EOF
cat > "$T/h-pytest-call" <<'EOF'
import unittest
import pytest


def test_x():
    pytest.skip("not now")
    assert add(1, 1) == 2
EOF
skip_case pytest-skip "$T/h-pytest-skip"
skip_case xfail "$T/h-xfail"
skip_case unittest-skip "$T/h-unittest-skip"
skip_case skipif "$T/h-skipif"
skip_case pytest-skip-call "$T/h-pytest-call"

R=$(mkrepo skip-skiptest)
put "$R" tests/test_a.py <<'EOF'
import unittest


class CalcCase(unittest.TestCase):
    def test_add(self):
        self.assertEqual(add(1, 1), 2)
EOF
B=$(commit "$R" base)
put "$R" tests/test_a.py <<'EOF'
import unittest


class CalcCase(unittest.TestCase):
    def test_add(self):
        self.skipTest("not now")
        self.assertEqual(add(1, 1), 2)
EOF
H=$(commit "$R" skiptest)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "python self.skipTest added exit 1"
has "$(jq -r '.entries[0].problem' <<<"$out")" '`CalcCase::test_add`' "python self.skipTest names the method"

R=$(mkrepo skip-class)
put "$R" tests/test_a.py <<'EOF'
import unittest


class CalcCase(unittest.TestCase):
    def test_add(self):
        self.assertEqual(add(1, 1), 2)
EOF
B=$(commit "$R" base)
put "$R" tests/test_a.py <<'EOF'
import unittest


@unittest.skip("whole class")
class CalcCase(unittest.TestCase):
    def test_add(self):
        self.assertEqual(add(1, 1), 2)
EOF
H=$(commit "$R" skip-class)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "python class-level skip exit 1"
has "$(jq -r '.entries[0].problem' <<<"$out")" '`CalcCase::test_add`' "python class-level skip names the method"

R=$(mkrepo skip-pre)
put "$R" tests/test_a.py <<'EOF'
import pytest


@pytest.mark.skip(reason="slow")
def test_slow():
    assert add(1, 1) == 2
EOF
B=$(commit "$R" base)
put "$R" tests/test_a.py <<'EOF'
import pytest


@pytest.mark.skip(reason="slow")
def test_slow():
    assert add(1, 1) == 2


def test_quick():
    assert add(2, 2) == 4
EOF
H=$(commit "$R" add-quick)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "python pre-existing skip untouched is clean"

# ---- R2 assert count per test fn (bare assert, self.assert*, pytest.raises, commented out) ----
R=$(mkrepo p4)
put "$R" tests/test_a.py <<'EOF'
def test_a():
    assert add(1, 1) == 2
    assert add(2, 2) == 4
EOF
B=$(commit "$R" base)
put "$R" tests/test_a.py <<'EOF'
def test_a():
    assert add(1, 1) == 2
EOF
H=$(commit "$R" drop-assert)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "python dropped assert exit 1"
eq "$(jq -r '.entries|length' <<<"$out")" 1 "python dropped assert: one entry"
eq "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable "python dropped assert class"
eq "$(jq -r '.entries[0].severity' <<<"$out")" fail "python dropped assert severity fail"
eq "$(jq -r '.entries[0].line' <<<"$out")" 1 "python per-fn entry line = head def line"
has "$(jq -r '.entries[0].problem' <<<"$out")" "from 2 to 1" "python dropped assert problem gives counts"
eq "$(jq -r '.entries[0].forbidden' <<<"$out")" "fewer asserts in test test_a" "python dropped assert forbidden names the fn"
eq "$(jq -r '.entries[0].id' <<<"$out")" "$(sid 'tests/test_a.pyassert-count:test_a')" "python assert-count id keyed by file + fn"

R=$(mkrepo p4self)
put "$R" tests/test_a.py <<'EOF'
import unittest


class CalcCase(unittest.TestCase):
    def test_a(self):
        self.assertEqual(add(1, 1), 2)
        self.assertTrue(add(2, 2))
EOF
B=$(commit "$R" base)
put "$R" tests/test_a.py <<'EOF'
import unittest


class CalcCase(unittest.TestCase):
    def test_a(self):
        self.assertEqual(add(1, 1), 2)
EOF
H=$(commit "$R" drop-self-assert)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "python dropped self.assertTrue exit 1"
has "$(jq -r '.entries[0].problem' <<<"$out")" "\`CalcCase::test_a\` dropped from 2 to 1" "python self.assert* counted per method"

R=$(mkrepo p4raises)
put "$R" tests/test_a.py <<'EOF'
import pytest


def test_raises():
    with pytest.raises(ValueError):
        parse("x")
    assert parse("1") == 1
EOF
B=$(commit "$R" base)
put "$R" tests/test_a.py <<'EOF'
import pytest


def test_raises():
    assert parse("1") == 1
EOF
H=$(commit "$R" drop-raises)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "python dropped pytest.raises exit 1"
has "$(jq -r '.entries[0].problem' <<<"$out")" "test \`test_raises\` dropped from 2 to 1" "python pytest.raises counts as an assertion"

R=$(mkrepo p4comment)
put "$R" tests/test_a.py <<'EOF'
def test_a():
    assert add(1, 1) == 2
    assert add(2, 2) == 4
EOF
B=$(commit "$R" base)
put "$R" tests/test_a.py <<'EOF'
def test_a():
    assert add(1, 1) == 2
    # assert add(2, 2) == 4
EOF
H=$(commit "$R" comment-assert)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "python commented-out assert counts as dropped"

R=$(mkrepo p4same)
put "$R" tests/test_a.py <<'EOF'
def test_a():
    assert len(v) == 1
EOF
B=$(commit "$R" base)
put "$R" tests/test_a.py <<'EOF'
def test_a():
    assert len(v) == 1 and v[0] == 3
EOF
H=$(commit "$R" stronger)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "python same assert count edited is clean (confirm at most)"

R=$(mkrepo p4prod)
put "$R" src/calc.py <<'EOF'
def f(x):
    assert x > 0
    return x
EOF
B=$(commit "$R" base)
put "$R" src/calc.py <<'EOF'
def f(x):
    return x
EOF
H=$(commit "$R" drop-prod-assert)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "python production assert removal is clean (not test code)"

R=$(mkrepo p4helper)
put "$R" tests/helpers.py <<'EOF'
def check_range(v):
    assert v > 0
    assert v < 10
EOF
B=$(commit "$R" base)
put "$R" tests/helpers.py <<'EOF'
def check_range(v):
    assert v > 0
EOF
H=$(commit "$R" drop-helper)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "python helper assert drop in a test-path file exit 1"
has "$(jq -r '.entries[0].problem' <<<"$out")" "outside test fns in \`tests/helpers.py\` dropped from 2 to 1" "python helper drop names the file"

R=$(mkrepo p4extract)
put "$R" tests/test_a.py <<'EOF'
def test_a():
    assert add(1, 1) == 2
    assert add(2, 2) == 4
EOF
B=$(commit "$R" base)
put "$R" tests/test_a.py <<'EOF'
def check_sum():
    assert add(2, 2) == 4


def test_a():
    assert add(1, 1) == 2
    check_sum()
EOF
H=$(commit "$R" extract)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "python assert moved to a helper the test calls is clean"

R=$(mkrepo p4uncalled)
put "$R" tests/test_a.py <<'EOF'
def test_a():
    assert add(1, 1) == 2
    assert add(2, 2) == 4
EOF
B=$(commit "$R" base)
put "$R" tests/test_a.py <<'EOF'
def check_sum():
    assert add(2, 2) == 4


def test_a():
    assert add(1, 1) == 2
EOF
H=$(commit "$R" move-uncalled)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "python assert moved to a helper the test does not call: exit 1"

# ---- R2 changed expected value -> confirm ----
R=$(mkrepo p5)
put "$R" tests/test_a.py <<'EOF'
def test_adds_two():
    assert add(2, 2) == 4
EOF
B=$(commit "$R" base)
put "$R" tests/test_a.py <<'EOF'
def test_adds_two():
    assert add(2, 2) == 5
EOF
H=$(commit "$R" change-expected)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "python changed expected value is confirm, exit 0"
eq "$(jq -r '.entries[0].severity' <<<"$out")" confirm "python changed expected severity confirm"
eq "$(jq -r '.entries[0].line' <<<"$out")" 2 "python changed expected line = head assert line"
eq "$(jq -r '.entries[0].id' <<<"$out")" "$(sid 'tests/test_a.pyexpected:test_adds_two|add(2,2)')" "python changed expected id keyed by fn + unchanged side"
has "$(jq -r '.entries[0].problem' <<<"$out")" "was 4, now 5" "python changed expected problem gives old and new"
R=$(mkrepo p5ut)
put "$R" tests/test_a.py <<'EOF'
import unittest


class CalcCase(unittest.TestCase):
    def test_add(self):
        self.assertEqual(add(2, 2), 4)
EOF
B=$(commit "$R" base)
put "$R" tests/test_a.py <<'EOF'
import unittest


class CalcCase(unittest.TestCase):
    def test_add(self):
        self.assertEqual(add(2, 2), 5)
EOF
H=$(commit "$R" change-expected-ut)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "python self.assertEqual changed expected is confirm, exit 0"
has "$(jq -r '.entries[0].problem' <<<"$out")" "was 4, now 5" "python assertEqual problem gives old and new"

# ---- R2 suppressions: # noqa and # type: ignore need a reason ----
supp_case() {  # supp_case <name> <added line> <expect rc>
  local R B H out
  R=$(mkrepo "supp-$1")
  put "$R" src/calc.py <<'EOF'
def f():
    return 1
EOF
  B=$(commit "$R" base)
  printf 'def f():\n    return 1\n\n\nx = 1  %s\n' "$2" > "$R/src/calc.py"
  H=$(commit "$R" supp)
  out=$(mr "$R" "$B" "$H"); rc=$?
  eq "$rc" "$3" "python suppression $1: exit $3"
  if [[ "$3" == 1 ]]; then
    eq "$(jq -r '.entries[0].check' <<<"$out")" R2 "python suppression $1: R2"
    eq "$(jq -r '.entries[0].severity' <<<"$out")" fail "python suppression $1: severity fail"
    eq "$(jq -r '.entries[0].line' <<<"$out")" 5 "python suppression $1: line of the comment"
    has "$(jq -r '.entries[0].problem' <<<"$out")" "without a reason" "python suppression $1: problem says no reason"
  fi
}
supp_case noqa-bare '# noqa' 1
supp_case noqa-code '# noqa: E501' 1
supp_case noqa-dash-only '# noqa: E501 -' 1
supp_case noqa-no-space-codes '# noqa:E501,F401' 1
supp_case type-ignore-bare '# type: ignore' 1
supp_case noqa-reason '# noqa: E501 — url literal' 0
supp_case noqa-reason-ascii '# noqa: E501 - url literal' 0
supp_case type-ignore-reason '# type: ignore[attr-defined]  # stub gap' 0

R=$(mkrepo supp-id)
put "$R" src/calc.py <<'EOF'
def f():
    return 1
EOF
B=$(commit "$R" base)
put "$R" src/calc.py <<'EOF'
def f():
    return 1


x = 1  # noqa: E501
EOF
H=$(commit "$R" supp-id)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$(jq -r '.entries[0].id' <<<"$out")" "$(sid 'src/calc.pynoqa E501')" "python suppression id keyed by file + codes"

R=$(mkrepo supp-string)
put "$R" src/calc.py <<'EOF'
def f():
    return 1
EOF
B=$(commit "$R" base)
put "$R" src/calc.py <<'EOF'
def f():
    return 1


MSG = "# noqa"
EOF
H=$(commit "$R" string)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "python # noqa inside a string is not a suppression"

R=$(mkrepo supp-pre)
put "$R" src/calc.py <<'EOF'
x = 1  # noqa: E501 - long literal
EOF
B=$(commit "$R" base)
put "$R" src/calc.py <<'EOF'
x = 1  # noqa: E501 - long literal


def g():
    return 2
EOF
H=$(commit "$R" add-g)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "python pre-existing suppression untouched is clean"

# ---- R2 unparseable file: a truthful fail, never a crash or a silent pass ----
R=$(mkrepo p7)
put "$R" src/calc.py <<'EOF'
def f():
    return 1
EOF
B=$(commit "$R" base)
put "$R" src/calc.py <<'EOF'
def f(:
    return 1
EOF
H=$(commit "$R" broken)
out=$(mr "$R" "$B" "$H" 2>"$T/err"); rc=$?
eq "$rc" 1 "python unparseable head file: exit 1, not a usage error"
eq "$(jq -r .checks.R2.status <<<"$out")" fail "python unparseable head file: R2 fail"
has "$(jq -r '.entries[0].problem' <<<"$out")" "does not parse" "python unparseable: problem says does not parse"
eq "$(jq -r '.entries[0].severity' <<<"$out")" fail "python unparseable: severity fail"
eq "$(jq -r '.entries[0].file' <<<"$out")" src/calc.py "python unparseable: file named"
eq "$(jq -r '.entries[0].line' <<<"$out")" 1 "python unparseable: line of the syntax error"
eq "$(wc -c < "$T/err" | tr -d ' ')" 0 "python unparseable: no traceback on stderr"

R=$(mkrepo p7base)
put "$R" tests/test_a.py <<'EOF'
def test_a(:
    assert 1 == 1
EOF
B=$(commit "$R" base)
put "$R" tests/test_a.py <<'EOF'
def test_a():
    assert 1 == 1
EOF
H=$(commit "$R" fixed)
out=$(mr "$R" "$B" "$H" 2>/dev/null); rc=$?
eq "$rc" 1 "python unparseable base test file: exit 1 (base cannot be compared)"
has "$(jq -r '.entries[0].problem' <<<"$out")" "does not parse" "python unparseable base: problem says does not parse"

# ---- protected paths work the same on python ----
R=$(mkrepo p8)
put "$R" .github/workflows/ci.yml <<'EOF'
on: push
EOF
B=$(commit "$R" base)
put "$R" .github/workflows/ci.yml <<'EOF'
on: pull_request
EOF
H=$(commit "$R" ci-change)
out=$(mr "$R" "$B" "$H" --protected-paths '.github/**'); rc=$?
eq "$rc" 1 "python protected path change exit 1"
eq "$(jq -r '.entries[0].class' <<<"$out")" needs-human "python protected class needs-human"

# ---- CLI: python is a stack; an unknown one is still a usage error ----
has "$(python3 -I "$MR" --help)" "{python,rust}" "help names the python stack"
out=$(python3 -I "$MR" r2 --repo "$R" --base "$B" --head "$H" --stack cobol 2>&1); rc=$?
eq "$rc" 2 "unknown stack still exit 2"
has "$out" "python" "unknown stack error lists python"

done_tests
