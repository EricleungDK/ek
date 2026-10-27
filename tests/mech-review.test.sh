source "$(dirname "$0")/lib.sh"
MR="$ROOT/scripts/mech-review.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# mkrepo <name>: fresh git repo on main, prints path
mkrepo() { local r="$T/$1"; mkdir -p "$r"; git -C "$r" init -q -b main; echo "$r"; }
# put <repo> <path>: write stdin to file (mkdir -p)
put() { mkdir -p "$(dirname "$1/$2")"; cat > "$1/$2"; }
# commit <repo> <msg>: stage all, commit, print sha
commit() { git -C "$1" add -A; git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "$2"; git -C "$1" rev-parse HEAD; }
# mr <repo> <base> <head> [extra args]: r2 with rust config
mr() { local r="$1" b="$2" h="$3"; shift 3; python3 -I "$MR" r2 --repo "$r" --base "$b" --head "$h" --stack rust --test-paths 'tests/**' "$@"; }

# slice 1: envelope + exit code on clean change
R=$(mkrepo s1)
put "$R" tests/a.rs <<'EOF'
#[test]
fn adds() {
    assert_eq!(1 + 1, 2);
}
EOF
B=$(commit "$R" base)
put "$R" src/lib.rs <<'EOF'
pub fn add(a: i32, b: i32) -> i32 { a + b }
EOF
H=$(commit "$R" feat)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "clean change exit 0"
eq "$(jq -r .summary <<<"$out")" "all pass $H" "all green renders all pass <head sha>"
eq "$(jq -r .head <<<"$out")" "$H" "envelope head sha"
eq "$(jq -r .base <<<"$out")" "$B" "envelope base sha"
eq "$(jq -r .ek <<<"$out")" "0.1.1" "envelope ek version from plugin.json"
eq "$(jq -r .checks.R2.status <<<"$out")" pass "R2 status pass"
eq "$(jq -r .checks.R1.note <<<"$out")" "not implemented" "skipped note"
eq "$(jq -r .checks.R1.status <<<"$out")" skipped "R1 skipped (not built yet)"
eq "$(jq -r .checks.R3.status <<<"$out")" skipped "R3 skipped"
eq "$(jq -r .checks.R4.status <<<"$out")" skipped "R4 skipped"
eq "$(jq -c .entries <<<"$out")" "[]" "clean change has no entries"

out=$(python3 -I "$MR" r2 --repo "$R" --head "$H" --stack rust 2>&1); rc=$?
eq "$rc" 2 "missing --base exit 2"
has "$out" "--base" "missing --base named in usage error"
out=$(python3 -I "$MR" r2 --repo "$R" --base "$B" --head "$H" --stack cobol 2>&1); rc=$?
eq "$rc" 2 "unknown stack exit 2"
has "$out" "cobol" "unknown stack named in error"
out=$(mr "$R" nope-ref "$H" 2>&1); rc=$?
eq "$rc" 2 "unknown ref exit 2"
has "$out" "nope-ref" "unknown ref named in error"

# slice 2: R2 removed test fn
R=$(mkrepo s2)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
}

#[test]
fn b() {
    assert_eq!(2, 2);
}
EOF2
B=$(commit "$R" base)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
}
EOF2
H=$(commit "$R" drop-b)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "removed test fn exit 1"
eq "$(jq -r .checks.R2.status <<<"$out")" fail "R2 status fail"
eq "$(jq -r '.entries|length' <<<"$out")" 2 "removed fn + file-level fewer-asserts (rules are independent)"
e() { jq -r ".entries[0].$1" <<<"$out"; }
eq "$(e check)" R2 "entry check R2"
eq "$(e class)" agent-fixable "entry class agent-fixable"
eq "$(e severity)" fail "entry severity fail"
eq "$(e file)" tests/a.rs "entry file"
eq "$(e line)" 7 "entry line = base line of removed fn"
has "$(e problem)" "b" "problem names the removed fn"
eq "$([[ -n "$(e hint)" ]] && echo yes)" yes "hint present"
eq "$([[ -n "$(e forbidden)" ]] && echo yes)" yes "forbidden present"
want_id="R2-$(printf '%s' 'R2tests/a.rsb' | sha1sum | cut -c1-8)"
eq "$(e id)" "$want_id" "id = R2- + sha1(check+file+test)[:8]"
has "$(jq -r .summary <<<"$out")" "fail" "summary fail"

# removed test in a src file (#[cfg(test)] mod) is caught too
R=$(mkrepo s2src)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }

#[cfg(test)]
mod tests {
    #[test]
    fn f_is_one() {
        assert_eq!(super::f(), 1);
    }
}
EOF2
B=$(commit "$R" base)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }
EOF2
H=$(commit "$R" drop)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "removed inline test fn exit 1"
eq "$(jq -r '.entries[0].file' <<<"$out")" src/lib.rs "inline test entry file"

# adding a test is clean
R=$(mkrepo s2add)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
}
EOF2
B=$(commit "$R" base)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
}

#[test]
fn b() {
    assert_eq!(2, 2);
}
EOF2
H=$(commit "$R" add-b)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "added test is clean"
eq "$(jq -r .summary <<<"$out")" "all pass $H" "added test all pass"

# slice 3: R2 added #[ignore] (skip marker)
R=$(mkrepo s3)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
}

#[test]
fn b() {
    assert_eq!(2, 2);
}
EOF2
B=$(commit "$R" base)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
}

#[test]
#[ignore]
fn b() {
    assert_eq!(2, 2);
}
EOF2
H=$(commit "$R" ignore-b)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "added #[ignore] exit 1"
eq "$(jq -r '.entries[0].check' <<<"$out")" R2 "ignore entry R2"
eq "$(jq -r '.entries[0].severity' <<<"$out")" fail "ignore severity fail"
eq "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable "ignore class agent-fixable"
eq "$(jq -r '.entries[0].line' <<<"$out")" 8 "ignore line = fn b line in head"
has "$(jq -r '.entries[0].problem' <<<"$out")" '`b`' "ignore problem names fn"
want="R2-$(printf '%s' 'R2tests/a.rsb' | sha1sum | cut -c1-8)"
eq "$(jq -r '.entries[0].id' <<<"$out")" "$want" "ignore id keyed by fn name"

# new test with #[ignore = "..."] is also a fail
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
}

#[test]
#[ignore = "flaky"]
fn b() {
    assert_eq!(2, 2);
}

#[test]
#[ignore = "todo"]
fn c() {
    assert_eq!(3, 3);
}
EOF2
H2=$(commit "$R" ignore-new)
out=$(mr "$R" "$B" "$H2"); rc=$?
eq "$rc" 1 "ignore = reason and new ignored test exit 1"
has "$(jq -r '.entries[].problem' <<<"$out")" '`c`' "new ignored test c flagged"

# marker already on base is not a new cheat
R=$(mkrepo s3pre)
put "$R" tests/a.rs <<'EOF2'
#[test]
#[ignore]
fn slow() {
    assert_eq!(1, 1);
}
EOF2
B=$(commit "$R" base)
put "$R" tests/a.rs <<'EOF2'
#[test]
#[ignore]
fn slow() {
    assert_eq!(1, 1);
}

#[test]
fn quick() {
    assert_eq!(2, 2);
}
EOF2
H=$(commit "$R" add-quick)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "pre-existing ignore untouched is clean"

# slice 4: R2 fewer asserts in a changed test file (per file)
R=$(mkrepo s4)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
    assert_eq!(2, 2);
}
EOF2
B=$(commit "$R" base)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
}
EOF2
H=$(commit "$R" drop-assert)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "dropped assert exit 1"
eq "$(jq -r '.entries|length' <<<"$out")" 1 "dropped assert one entry"
eq "$(jq -r '.entries[0].check' <<<"$out")" R2 "dropped assert R2"
eq "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable "dropped assert class"
eq "$(jq -r '.entries[0].severity' <<<"$out")" fail "dropped assert severity fail"
eq "$(jq -r '.entries[0].file' <<<"$out")" tests/a.rs "dropped assert file"
eq "$(jq -r '.entries[0].line' <<<"$out")" 0 "file-level entry line 0"
has "$(jq -r '.entries[0].problem' <<<"$out")" "from 2 to 1" "problem gives counts"
eq "$(jq -r '.entries[0].forbidden' <<<"$out")" "fewer asserts in changed test file tests/a.rs" "forbidden names file"
eq "$(jq -r '.entries[0].id' <<<"$out")" "R2-$(printf '%s' 'R2tests/a.rsassert-count' | sha1sum | cut -c1-8)" "assert id keyed by file+assert-count"

# commenting an assert out is a drop
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
    // assert_eq!(2, 2);
}
EOF2
H2=$(commit "$R" comment-assert)
out=$(mr "$R" "$B" "$H2"); rc=$?
eq "$rc" 1 "commented-out assert counts as dropped"

# same count, edited body: clean
R=$(mkrepo s4same)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert!(v.len() == 1);
}
EOF2
B=$(commit "$R" base)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert!(v.len() == 1 && v[0] == 3);
}
EOF2
H=$(commit "$R" stronger)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "same assert count edited is clean"

# production debug_assert removed: not a test assert, clean
R=$(mkrepo s4prod)
put "$R" src/lib.rs <<'EOF2'
pub fn f(x: i32) -> i32 {
    debug_assert!(x > 0);
    x
}
EOF2
B=$(commit "$R" base)
put "$R" src/lib.rs <<'EOF2'
pub fn f(x: i32) -> i32 {
    x
}
EOF2
H=$(commit "$R" drop-debug)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "production debug_assert removal is clean"

# inline test assert dropped in src file: fail
R=$(mkrepo s4inline)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }

#[cfg(test)]
mod tests {
    #[test]
    fn f_is_one() {
        assert_eq!(super::f(), 1);
        assert!(super::f() > 0);
    }
}
EOF2
B=$(commit "$R" base)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }

#[cfg(test)]
mod tests {
    #[test]
    fn f_is_one() {
        assert_eq!(super::f(), 1);
    }
}
EOF2
H=$(commit "$R" drop-inline)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "inline test assert drop exit 1"
eq "$(jq -r '.entries[0].file' <<<"$out")" src/lib.rs "inline drop names src file"

# helper (no #[test]) in a test path: whole file counts
R=$(mkrepo s4helper)
put "$R" tests/helpers.rs <<'EOF2'
pub fn check(v: i32) {
    assert!(v > 0);
    assert!(v < 10);
}
EOF2
B=$(commit "$R" base)
put "$R" tests/helpers.rs <<'EOF2'
pub fn check(v: i32) {
    assert!(v > 0);
}
EOF2
H=$(commit "$R" drop-helper)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "helper assert drop in test path exit 1"

# slice 5: R2 added suppression without a reason
R=$(mkrepo s5)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }
EOF2
B=$(commit "$R" base)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }

#[allow(dead_code)]
fn g() {}
EOF2
H=$(commit "$R" allow-bare)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "bare #[allow] exit 1"
eq "$(jq -r '.entries[0].check' <<<"$out")" R2 "suppression R2"
eq "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable "suppression class"
eq "$(jq -r '.entries[0].severity' <<<"$out")" fail "suppression severity fail"
eq "$(jq -r '.entries[0].line' <<<"$out")" 3 "suppression line = attr line in head"
has "$(jq -r '.entries[0].problem' <<<"$out")" "dead_code" "problem names lint"
eq "$(jq -r '.entries[0].id' <<<"$out")" "R2-$(printf '%s' 'R2src/lib.rsdead_code' | sha1sum | cut -c1-8)" "suppression id keyed by file+lint"

# reason in the attribute: clean
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }

#[allow(dead_code, reason = "used by ffi")]
fn g() {}
EOF2
H2=$(commit "$R" allow-reason)
out=$(mr "$R" "$B" "$H2"); rc=$?
eq "$rc" 0 "allow with reason = clean"

# same-line reason comment: clean
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }

#[allow(dead_code)] // used by ffi
fn g() {}
EOF2
H3=$(commit "$R" allow-comment)
out=$(mr "$R" "$B" "$H3"); rc=$?
eq "$rc" 0 "allow with same-line reason comment = clean"

# suppression already on base, unrelated edit: clean
R=$(mkrepo s5pre)
put "$R" src/lib.rs <<'EOF2'
#[allow(dead_code)]
fn g() {}
EOF2
B=$(commit "$R" base)
put "$R" src/lib.rs <<'EOF2'
#[allow(dead_code)]
fn g() {}

pub fn h() -> i32 { 2 }
EOF2
H=$(commit "$R" add-h)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "pre-existing allow untouched is clean"

# slice 6: changed expected value -> confirm; protected path -> fail needs-human
R=$(mkrepo s6)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn adds_two() {
    assert_eq!(add(2, 2), 4);
}
EOF2
B=$(commit "$R" base)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn adds_two() {
    assert_eq!(add(2, 2), 5);
}
EOF2
H=$(commit "$R" change-expected)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "changed expected value is confirm, exit 0"
eq "$(jq -r '.entries[0].severity' <<<"$out")" confirm "changed expected severity confirm"
eq "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable "changed expected class agent-fixable"
eq "$(jq -r '.entries[0].line' <<<"$out")" 3 "changed expected line = head assert line"
eq "$(jq -r '.entries[0].id' <<<"$out")" "R2-$(printf '%s' 'R2tests/a.rsadds_two' | sha1sum | cut -c1-8)" "changed expected id keyed by test fn"
has "$(jq -r .summary <<<"$out")" "confirm" "summary confirm, not all pass"
has "$(jq -r '.entries[0].problem' <<<"$out")" "was 4, now 5" "problem gives old and new values"
eq "$(jq -r '.entries[0].forbidden' <<<"$out")" "editing an expected value to match the code's current output" "changed expected forbidden text"

# no protected paths configured: .github change is not flagged
R=$(mkrepo s6none)
put "$R" .github/workflows/ci.yml <<'EOF2'
on: push
EOF2
B=$(commit "$R" base)
put "$R" .github/workflows/ci.yml <<'EOF2'
on: pull_request
EOF2
H=$(commit "$R" ci-change)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "unconfigured protected path not flagged"

# protected path changed: fail, needs-human
out=$(mr "$R" "$B" "$H" --protected-paths '.github/**'); rc=$?
eq "$rc" 1 "protected path change exit 1"
eq "$(jq -r '.entries[0].class' <<<"$out")" needs-human "protected class needs-human"
eq "$(jq -r '.entries[0].severity' <<<"$out")" fail "protected severity fail"
eq "$(jq -r '.entries[0].check' <<<"$out")" R2 "protected check R2"
eq "$(jq -r '.entries[0].file' <<<"$out")" .github/workflows/ci.yml "protected file"
eq "$(jq -r '.entries[0].id' <<<"$out")" "R2-$(printf '%s' 'R2.github/workflows/ci.ymlprotected-path' | sha1sum | cut -c1-8)" "protected id keyed by file+protected-path"
eq "$(jq -r '.entries[0].line' <<<"$out")" 0 "protected entry file-level"

# slice 7: guard exceptions (PR body) downgrade agent-fixable fails to confirm
R=$(mkrepo s7)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
}

#[test]
fn b() {
    assert_eq!(2, 2);
}
EOF2
B=$(commit "$R" base)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
}
EOF2
H=$(commit "$R" drop-b)
ID="R2-$(printf '%s' 'R2tests/a.rsb' | sha1sum | cut -c1-8)"
AC="R2-$(printf '%s' 'R2tests/a.rsassert-count' | sha1sum | cut -c1-8)"
OTHER="R2-$(printf '%s' 'R2tests/a.rszzz' | sha1sum | cut -c1-8)"
body() { printf '%s\n' "$@" > "$T/body.md"; echo "$T/body.md"; }

f=$(body "## Summary" "removes b" "## Guard exceptions" "- $ID: b superseded by a stronger test in a.rs" "- $AC: a lost its assert on purpose, see $ID")
out=$(mr "$R" "$B" "$H" --pr-body "$f"); rc=$?
eq "$rc" 0 "listed ids with reason: exit 0 (removed fn and its companion assert-count)"
eq "$(jq -r '.entries[0].severity' <<<"$out")" confirm "listed id downgraded to confirm"
eq "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable "downgrade keeps class"
eq "$(jq -r '[.entries[].severity]|unique|join(",")' <<<"$out")" confirm "every listed entry downgraded"
has "$(jq -r .summary <<<"$out")" "confirm" "summary confirm after downgrade"

f=$(body "## Guard exceptions" "**Guard exceptions**" "- $ID")
out=$(mr "$R" "$B" "$H" --pr-body "$f"); rc=$?
eq "$rc" 1 "listed id without reason stays fail"
eq "$(jq -r '.entries[0].severity' <<<"$out")" fail "no-reason severity still fail"

f=$(body "## Guard exceptions" "- $OTHER: unrelated id, reason given here")
out=$(mr "$R" "$B" "$H" --pr-body "$f"); rc=$?
eq "$rc" 1 "other id does not match"

f=$(body "## Summary" "- $ID: mentioned outside the section, reason here")
out=$(mr "$R" "$B" "$H" --pr-body "$f"); rc=$?
eq "$rc" 1 "id outside Guard exceptions section does not match"

f=$(body "# PR" "Guard exceptions" "no list here")
out=$(mr "$R" "$B" "$H" --pr-body "$f"); rc=$?
eq "$rc" 1 "heading without ids does nothing"

out=$(mr "$R" "$B" "$H" --pr-body "$T/missing.md" 2>&1); rc=$?
eq "$rc" 2 "missing pr body file exit 2"

# protected entries are never downgraded by guard exceptions
R=$(mkrepo s7prot)
put "$R" .github/workflows/ci.yml <<'EOF2'
on: push
EOF2
B=$(commit "$R" base)
put "$R" .github/workflows/ci.yml <<'EOF2'
on: pull_request
EOF2
H=$(commit "$R" ci-change)
PID="R2-$(printf '%s' 'R2.github/workflows/ci.ymlprotected-path' | sha1sum | cut -c1-8)"
f=$(body "## Guard exceptions" "- $PID: ci change needed for the fix, reviewer please confirm")
out=$(mr "$R" "$B" "$H" --protected-paths '.github/**' --pr-body "$f"); rc=$?
eq "$rc" 1 "protected entry not downgraded by exception: exit 1"
eq "$(jq -r '.entries[0].severity' <<<"$out")" fail "protected stays fail"
eq "$(jq -r '.entries[0].class' <<<"$out")" needs-human "protected stays needs-human"

# slice 8: ids stable when lines move, change when the test changes
R=$(mkrepo s8)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
}

#[test]
fn b() {
    assert_eq!(2, 2);
}
EOF2
B=$(commit "$R" base)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
}
EOF2
H1=$(commit "$R" drop-b)
id1=$(mr "$R" "$B" "$H1" | jq -r '[.entries[] | select(.problem|contains("removed"))][0].id')
put "$R" tests/a.rs <<'EOF2'
// header comment
// another

#[test]
fn a() {
    assert_eq!(1, 1);
}
EOF2
H2=$(commit "$R" drop-b-lines-moved)
id2=$(mr "$R" "$B" "$H2" | jq -r '[.entries[] | select(.problem|contains("removed"))][0].id')
eq "$id2" "$id1" "removed-fn id unchanged when lines move"
has "$id1" "R2-" "removed-fn id has R2 prefix"

# suppression: same id after lines move
R=$(mkrepo s8allow)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }

#[allow(dead_code)]
fn g() {}
EOF2
B=$(commit "$R" base)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }

#[allow(dead_code)]
fn g() {}

pub fn h() {}
EOF2
H1=$(commit "$R" allow-lines-a)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }

pub fn extra() {}

#[allow(dead_code)]
fn g() {}

pub fn h() {}
EOF2
H2=$(commit "$R" allow-lines-b)
id1=$(mr "$R" "$B" "$H1" | jq -r '.entries[0].id')
id2=$(mr "$R" "$B" "$H2" | jq -r '.entries[0].id')
eq "$id2" "$id1" "suppression id unchanged when lines move"

# a different test name is a different failure
R=$(mkrepo s8name)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
}

#[test]
fn b() {
    assert_eq!(2, 2);
}
EOF2
B=$(commit "$R" base)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
}

#[test]
fn c() {
    assert_eq!(2, 2);
}
EOF2
H=$(commit "$R" rename-b-c)
out=$(mr "$R" "$B" "$H")
has "$(jq -r '[.entries[].id] | join(" ")' <<<"$out")" "R2-" "rename yields entries"
eq "$(jq -r '[.entries[].id] | unique | length' <<<"$out")" "$(jq -r '.entries|length' <<<"$out")" "entry ids unique"
has "$(jq -r '[.entries[].problem] | join(" ")' <<<"$out")" '`b`' "rename reports removed b"

done_tests
