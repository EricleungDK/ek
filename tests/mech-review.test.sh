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
eq "$(jq -r '.entries|length' <<<"$out")" 1 "removed fn yields one entry (its asserts are not counted as dropped)"
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
want="R2-$(printf '%s' 'R2tests/a.rsignore:b' | sha1sum | cut -c1-8)"
eq "$(jq -r '.entries[0].id' <<<"$out")" "$want" "ignore id keyed by ignore:fn"

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

# helper in a test-path file: whole file counts
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
eq "$rc" 1 "helper assert drop in test-path file exit 1"

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
eq "$(jq -r '.entries[0].id' <<<"$out")" "R2-$(printf '%s' 'R2tests/a.rsexpected:adds_two|add(2,2)' | sha1sum | cut -c1-8)" "changed expected id keyed by fn + unchanged side"
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

# slice 7 (#27): guard exceptions removed. --pr-body is a usage error; a fail stays fail whatever a PR body says.
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
body() { printf '%s\n' "$@" > "$T/body.md"; echo "$T/body.md"; }

f=$(body "## Guard exceptions" "- $ID: b superseded by a stronger test in a.rs")
out=$(mr "$R" "$B" "$H" --pr-body "$f" 2>&1); rc=$?
eq "$rc" 2 "--pr-body listing a fail id: usage error exit 2"
has "$out" "guard exceptions were removed (#27)" "--pr-body error says guard exceptions removed"
stdout=$(mr "$R" "$B" "$H" --pr-body "$f" 2>/dev/null)
eq "$stdout" "" "--pr-body: no envelope on stdout (cannot read as pass)"
out=$(mr "$R" "$B" "$H" --pr-body="$f" 2>&1); rc=$?
eq "$rc" 2 "--pr-body=FILE form: usage error exit 2"
out=$(mr "$R" "$B" "$H" --pr-body 2>&1); rc=$?
eq "$rc" 2 "bare --pr-body: usage error exit 2"
has "$out" "guard exceptions were removed (#27)" "bare --pr-body names the removal"
out=$(mr "$R" "$B" "$H" --pr-body "$T/missing.md" 2>&1); rc=$?
eq "$rc" 2 "--pr-body missing file: usage error exit 2"

out=$(python3 -I "$MR" --help); rc=$?
has "$out" "Guard exceptions removed (#27)" "--help says guard exceptions removed"

# no body read: the listed id stays a fail, agent-fixable
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "listed fail id without --pr-body: exit 1"
eq "$(jq -r '.entries[0].severity' <<<"$out")" fail "listed fail id: severity stays fail"
eq "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable "listed fail id: class stays agent-fixable"

# protected entries: --pr-body rejected; without it still fail needs-human
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
out=$(mr "$R" "$B" "$H" --protected-paths '.github/**' --pr-body "$f" 2>&1); rc=$?
eq "$rc" 2 "--pr-body listing protected id: usage error exit 2"
out=$(mr "$R" "$B" "$H" --protected-paths '.github/**'); rc=$?
eq "$rc" 1 "protected change without body: exit 1"
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

# suppression: same id after lines move (allow added in each head, so the entry exists)
R=$(mkrepo s8allow)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }

fn g() {}
EOF2
B=$(commit "$R" base)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }

#[allow(dead_code)]
fn g() {}
EOF2
H1=$(commit "$R" allow-added)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }

pub fn extra() {}

#[allow(dead_code)]
fn g() {}
EOF2
H2=$(commit "$R" allow-lines-moved)
id1=$(mr "$R" "$B" "$H1" | jq -r '.entries[0].id')
id2=$(mr "$R" "$B" "$H2" | jq -r '.entries[0].id')
eq "$([[ -n $id1 && $id1 != null ]] && echo yes)" yes "suppression entry exists in head 1"
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

# slice 9: all pass renders `all pass <sha>` (text + json); `all` subcommand; text fail output
R=$(mkrepo s9)
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
fn b() {
    assert_eq!(2, 2);
}

#[test]
fn c() {
    assert_eq!(3, 3);
}
EOF2
H=$(commit "$R" add-c)
out=$(mr "$R" "$B" "$H" --format text); rc=$?
eq "$rc" 0 "text clean exit 0"
eq "$out" "all pass $H" "text clean is exactly all pass <sha>"

out=$(python3 -I "$MR" all --repo "$R" --base "$B" --head "$H" --stack rust); rc=$?
eq "$rc" 0 "all subcommand clean exit 0"
eq "$(jq -r .summary <<<"$out")" "all pass $H" "all subcommand summary"

put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
}

#[test]
fn c() {
    assert_eq!(3, 3);
}
EOF2
H2=$(commit "$R" drop-b)
out=$(mr "$R" "$B" "$H2" --format text); rc=$?
eq "$rc" 1 "text fail exit 1"
eq "$(head -1 <<<"$out")" "fail $H2 (1 fail, 0 confirm)" "text fail summary line"
has "$out" "R2-" "text lists entry id"
has "$out" "tests/a.rs" "text lists file"
has "$out" "hint:" "text shows hint"
has "$out" "forbidden:" "text shows forbidden"

# round 2 area 1: lexer (nested comments, multi-line strings), test attrs, ignore markers, macros, renames
R=$(mkrepo r1nest)
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
/* outer /* inner */ #[test] fn b() { assert_eq!(2, 2); } */
#[test]
fn a() {
    assert_eq!(1, 1);
}
EOF2
H=$(commit "$R" hide-b-nested)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "nested block comment hides b: removal caught"
has "$(jq -r '[.entries[].problem] | join(" ")' <<<"$out")" '`b`' "nested comment: removed b named"

R=$(mkrepo r1str)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    let s = "run
/* x";
    assert_eq!(s.len(), 6);
}
#[test]
fn b() {
    assert_eq!(2, 2);
}
/* end */
EOF2
B=$(commit "$R" base)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    let s = "run
/* x";
    assert_eq!(s.len(), 6);
}
/* end */
EOF2
H=$(commit "$R" drop-b)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "multi-line string containing /* does not hide fn b"
has "$(jq -r '[.entries[].problem] | join(" ")' <<<"$out")" '`b`' "multi-line string: removed b named"

R=$(mkrepo r1lt)
put "$R" tests/a.rs <<'EOF2'
fn id<'a>(x: &'a str) -> &'a str { x }
#[test]
fn a() {
    let c = '{';
    assert_eq!(id("x"), "x");
    assert_eq!(c, '{');
}
#[test]
fn b() {
    assert_eq!(2, 2);
}
EOF2
B=$(commit "$R" base)
put "$R" tests/a.rs <<'EOF2'
fn id<'a>(x: &'a str) -> &'a str { x }
#[test]
fn a() {
    let c = '{';
    assert_eq!(id("x"), "x");
    assert_eq!(c, '{');
}
EOF2
H=$(commit "$R" drop-b-lifetimes)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "lifetimes and char literals: removed b caught"

R=$(mkrepo r1cfg)
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
#[cfg_attr(test, ignore)]
fn b() {
    assert_eq!(2, 2);
}
EOF2
H=$(commit "$R" cfg-attr-ignore)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "cfg_attr(test, ignore) is an ignore marker"
has "$(jq -r '[.entries[].problem] | join(" ")' <<<"$out")" '`b`' "cfg_attr ignore names b"
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
}

#[test]
#[cfg(any())]
fn b() {
    assert_eq!(2, 2);
}
EOF2
H=$(commit "$R" cfg-any-off)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "cfg(any()) disabling a test is an ignore marker"
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
}

#[test]
#[cfg(FALSE)]
fn b() {
    assert_eq!(2, 2);
}
EOF2
H=$(commit "$R" cfg-false-off)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "cfg(FALSE) disabling a test is an ignore marker"

R=$(mkrepo r1attr)
put "$R" tests/a.rs <<'EOF2'
#[rstest]
fn a() {
    assert_eq!(1, 1);
}

#[test_case(2)]
fn b() {
    assert_eq!(2, 2);
}

#[async_std::test]
async fn c() {
    assert_eq!(3, 3);
}
EOF2
B=$(commit "$R" base)
put "$R" tests/a.rs <<'EOF2'
EOF2
H=$(commit "$R" drop-all-attr-tests)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "rstest/test_case/path::test fns are test fns"
eq "$(jq '[.entries[] | select(.problem|contains("removed"))] | length' <<<"$out")" 3 "three removed test fns found"

R=$(mkrepo r1macro)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_relative_eq!(x, 1.0, epsilon = 0.1);
    prop_assert!(y);
    insta::assert_snapshot!(z);
}
EOF2
B=$(commit "$R" base)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_relative_eq!(x, 1.0, epsilon = 0.1);
    prop_assert!(y);
}
EOF2
H=$(commit "$R" drop-snapshot)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "insta snapshot assert counted"
has "$(jq -r '[.entries[].problem] | join(" ")' <<<"$out")" "from 3 to 2" "macro asserts counted 3 to 2"

R=$(mkrepo r1mv)
{ for k in $(seq 1 30); do echo "// filler $k"; done; cat <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
}

#[test]
fn b() {
    assert_eq!(2, 2);
}
EOF2
} | put "$R" tests/a.rs
B=$(commit "$R" base)
git -C "$R" mv tests/a.rs tests/a.rs.off
{ for k in $(seq 1 30); do echo "// filler $k"; done; cat <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
}
EOF2
} | put "$R" tests/a.rs.off
H=$(commit "$R" rename-off-drop-b)
eq "$(git -C "$R" diff -M --name-status "$B" "$H" | cut -c1)" R "git sees a rename (R), not delete plus add"
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "rename out of .rs that drops b is caught"
eq "$(jq -r '[.entries[] | select(.problem|contains("removed"))][0].file' <<<"$out")" tests/a.rs "renamed-out removal reported at old path"

# item 11: lexer survivors, one file holds the literal and the tests (pass on HEAD; each kills a masking mutant)
R=$(mkrepo lexg1)
put "$R" src/lib.rs <<'EOF2'
pub const P: &str = r"C:\";
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
put "$R" src/lib.rs <<'EOF2'
pub const P: &str = r"C:\";
#[test]
fn a() {
    assert_eq!(1, 1);
}
EOF2
H=$(commit "$R" drop-b)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "G1 raw string ending in backslash, then tests: removed b caught"

R=$(mkrepo lexg2)
put "$R" src/lib.rs <<'EOF2'
#[test]
fn a() {
    let c = '}';
    assert_eq!(c, '}');
    assert_eq!(1, 1);
}
EOF2
B=$(commit "$R" base)
put "$R" src/lib.rs <<'EOF2'
#[test]
fn a() {
    let c = '}';
    assert_eq!(c, '}');
}
EOF2
H=$(commit "$R" drop-trailing-assert)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "G2 char literal '}' does not end the body: trailing assert drop caught"

R=$(mkrepo lexg3)
put "$R" src/lib.rs <<'EOF2'
pub const Q: char = '\"';
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
put "$R" src/lib.rs <<'EOF2'
pub const Q: char = '\"';
#[test]
fn a() {
    assert_eq!(1, 1);
}
EOF2
H=$(commit "$R" drop-b)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "G3 escaped-quote char literal: removed b caught"

R=$(mkrepo lexg4)
put "$R" src/lib.rs <<'EOF2'
pub const S: &str = "a\"/*";
#[test]
fn a() {
    assert_eq!(1, 1);
}

#[test]
fn b() {
    assert_eq!(2, 2);
}
*/
EOF2
B=$(commit "$R" base)
put "$R" src/lib.rs <<'EOF2'
pub const S: &str = "a\"/*";
#[test]
fn a() {
    assert_eq!(1, 1);
}
*/
EOF2
H=$(commit "$R" drop-b)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "G4 string with escaped quote and /*: removed b caught"

# round 2 area 2: expected-value pairing (whitespace, either side, == in assert!), reflow, keys, scope
R=$(mkrepo r2ws)
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
    assert_eq!(add(2,2), 5);
}
EOF2
H=$(commit "$R" ws-subject)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "whitespace-changed subject with changed expected: confirm, exit 0"
eq "$(jq -r '.entries[0].severity' <<<"$out")" confirm "whitespace subject: confirm"
eq "$(jq -r '.entries[0].id' <<<"$out")" "R2-$(printf '%s' 'R2tests/a.rsexpected:adds_two|add(2,2)' | sha1sum | cut -c1-8)" "whitespace subject: id keyed by unchanged side"

put "$R" tests/a.rs <<'EOF2'
#[test]
fn adds_two() {
    assert_eq!(4, add(2, 2));
}
EOF2
B2=$(commit "$R" base-lhs)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn adds_two() {
    assert_eq!(5, add(2, 2));
}
EOF2
H2=$(commit "$R" lhs-changed)
out=$(mr "$R" "$B2" "$H2"); rc=$?
eq "$(jq -r '.entries[0].severity' <<<"$out")" confirm "expected on the left side changed: confirm"
eq "$(jq -r '.entries[0].id' <<<"$out")" "R2-$(printf '%s' 'R2tests/a.rsexpected:adds_two|add(2,2)' | sha1sum | cut -c1-8)" "left expected: key from unchanged right side"
has "$(jq -r '.entries[0].problem' <<<"$out")" "was 4, now 5" "left expected: old and new"

R=$(mkrepo r2cmp)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn t() {
    assert!(v == 3);
}
EOF2
B=$(commit "$R" base)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn t() {
    assert!(v == 4);
}
EOF2
H=$(commit "$R" cmp-changed)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "assert!(a == b) expected change: confirm"
eq "$(jq -r '.entries[0].severity' <<<"$out")" confirm "assert!(==) changed value is confirm"

R=$(mkrepo r2reflow)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn t() {
    assert_eq!(v, vec![1, 2]);
}
EOF2
B=$(commit "$R" base)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn t() {
    assert_eq!(
        v,
        vec![1, 2],
    );
}
EOF2
H=$(commit "$R" reflow)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "rustfmt reflow of args is not a value change"
eq "$(jq -c .entries <<<"$out")" "[]" "reflow: no entries"

R=$(mkrepo r2both)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
}
EOF2
B=$(commit "$R" base)
put "$R" tests/a.rs <<'EOF2'
#[test]
#[ignore]
fn a() {
    assert_eq!(1, 2);
}
EOF2
H=$(commit "$R" ignore-and-value)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$(jq -r '.entries|length' <<<"$out")" 2 "ignore and value change in same fn: two entries"
eq "$(jq -r '[.entries[].id]|unique|length' <<<"$out")" 2 "those two entries have distinct ids"
eq "$(jq -r '[.entries[].severity]|sort|join(",")' <<<"$out")" "confirm,fail" "one fail (ignore) and one confirm (value)"

R=$(mkrepo r2two)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(x, 1);
    assert_eq!(y, 2);
}
EOF2
B=$(commit "$R" base)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(x, 9);
    assert_eq!(y, 8);
}
EOF2
H=$(commit "$R" two-values)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$(jq -r '.entries|length' <<<"$out")" 2 "two value changes in one fn: two entries"
eq "$(jq -r '[.entries[].severity]|unique|join(",")' <<<"$out")" confirm "both are confirm"

R=$(mkrepo r2helper)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn t() {
        assert_eq!(f(), 1);
    }
}
EOF2
B=$(commit "$R" base)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }

#[cfg(test)]
mod tests {
    use super::*;

    fn check(v: i32) {
        assert_eq!(v, 1);
    }

    #[test]
    fn t() {
        check(f());
    }
}
EOF2
H=$(commit "$R" extract-helper)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "assert moved into a helper inside cfg(test) mod: not a drop"

R=$(mkrepo r2prod)
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
H=$(commit "$R" drop-prod-debug)
out=$(python3 -I "$MR" r2 --repo "$R" --base "$B" --head "$H" --stack rust --test-paths 'tests/**'); rc=$?
eq "$rc" 0 "production file outside test paths: debug_assert removal not counted"

# round 2 area 3: suppressions on masked head text (multi-line, cfg_attr, doc/raw strings), path with space
R=$(mkrepo r3multi)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }
EOF2
B=$(commit "$R" base)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }

#[allow(
    dead_code
)]
fn g() {}
EOF2
H=$(commit "$R" multiline-allow)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "multi-line #[allow( dead_code )] without reason: exit 1"
eq "$(jq -r '.entries[0].line' <<<"$out")" 3 "multi-line allow: line = attr start"
has "$(jq -r '.entries[0].problem' <<<"$out")" "dead_code" "multi-line allow names lint"

R=$(mkrepo r3cfg)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }
EOF2
B=$(commit "$R" base)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }

#[cfg_attr(not(test), allow(dead_code))]
fn g() {}
EOF2
H=$(commit "$R" cfg-attr-allow)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "cfg_attr(..., allow(dead_code)) without reason: exit 1"

R=$(mkrepo r3doc)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }
EOF2
B=$(commit "$R" base)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }

/// use `#[allow(dead_code)]` to silence this
pub fn g() -> i32 { 2 }
EOF2
H=$(commit "$R" doc-mention)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "#[allow] inside a doc comment is not a suppression"

R=$(mkrepo r3raw)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }
EOF2
B=$(commit "$R" base)
put "$R" src/lib.rs <<'EOF2'
pub fn f() -> i32 { 1 }

pub fn doc() -> &'static str { r#"#[allow(dead_code)]"# }
EOF2
H=$(commit "$R" raw-mention)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "#[allow] inside a raw string is not a suppression"

R=$(mkrepo r3space)
put "$R" "src/my mod.rs" <<'EOF2'
pub fn f() -> i32 { 1 }
EOF2
B=$(commit "$R" base)
put "$R" "src/my mod.rs" <<'EOF2'
pub fn f() -> i32 { 1 }

#[allow(dead_code)]
fn g() {}
EOF2
H=$(commit "$R" space-path)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "path with a space: suppression caught"
eq "$(jq -r '.entries[0].file' <<<"$out")" "src/my mod.rs" "path with a space reported verbatim"

# round 2 area 4: confirm-only summary

R=$(mkrepo r4sum)
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
eq "$(jq -r .summary <<<"$out")" "pass $H, 1 confirm" "confirm-only renders pass <sha>, n confirm (never all pass)"

# round 3 red: scope, cfg attrs, raw C strings, pr-body encoding, binary diffs, non-utf8 and control-char names, ordinals

# item 2: top-level helper extracted from test t in a test-path file: not a drop
R=$(mkrepo r6helper)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn t() {
    assert_eq!(f(), 1);
}
EOF2
B=$(commit "$R" base)
put "$R" tests/a.rs <<'EOF2'
fn check(v: i32) {
    assert_eq!(v, 1);
}

#[test]
fn t() {
    check(f());
}
EOF2
H=$(commit "$R" extract-top-helper)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 0 "extracted top-level helper in test path: not a drop"

# item 3: #[cfg(test)] followed by other attributes before mod
R=$(mkrepo r6mod)
put "$R" src/lib.rs <<'EOF2'
pub fn f(v: i32) -> i32 { v }
#[cfg(test)]
#[allow(clippy::all)]
mod tests {
    use super::*;
    fn check(v: i32) {
        assert!(v > 0);
        assert!(v < 10);
    }
    #[test]
    fn t() { check(f(1)); }
}
EOF2
B=$(commit "$R" base)
put "$R" src/lib.rs <<'EOF2'
pub fn f(v: i32) -> i32 { v }
#[cfg(test)]
#[allow(clippy::all)]
mod tests {
    use super::*;
    fn check(v: i32) {
        assert!(v > 0);
    }
    #[test]
    fn t() { check(f(1)); }
}
EOF2
H=$(commit "$R" drop-helper-assert-attr)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "cfg(test) mod with extra attr: helper assert drop caught"
has "$(jq -r '[.entries[].problem] | join(" ")' <<<"$out")" "from 2 to 1" "module helper counted 2 to 1"

# item 4: raw C string is masked (cr"..." has no escapes; a \" must not open a string)
R=$(mkrepo r6rawc)
put "$R" tests/a.rs <<'EOF2'
pub const CR: &core::ffi::CStr = cr"a\";
pub const X: u8 = 1;
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
pub const CR: &core::ffi::CStr = cr"a\";
pub const X: u8 = 1;
#[test]
fn a() {
    assert_eq!(1, 1);
}
EOF2
H=$(commit "$R" drop-b-after-cr)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "after cr\"a\\\" raw C string: removed b caught"
has "$(jq -r '[.entries[].problem] | join(" ")' <<<"$out")" '`b`' "removed b named after raw C string"

R=$(mkrepo r6rawc2)
put "$R" tests/a.rs <<'EOF2'
pub const CH: &core::ffi::CStr = cr#"a"#;
pub const CC: &core::ffi::CStr = c"x\"y";
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
pub const CH: &core::ffi::CStr = cr#"a"#;
pub const CC: &core::ffi::CStr = c"x\"y";
#[test]
fn a() {
    assert_eq!(1, 1);
}
EOF2
H=$(commit "$R" drop-b-after-cr-hash)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "after cr#\"a\"# and c\"x\\\"y\": removed b caught"

# item 5: #[cfg(not(test))] on a test fn disables it (ignore marker); cfg(feature) is left alone
R=$(mkrepo r6cfgnot)
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
#[cfg(not(test))]
fn b() {
    assert_eq!(2, 2);
}
EOF2
H=$(commit "$R" cfg-not-test)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "cfg(not(test)) on a test fn is an ignore marker"
has "$(jq -r '[.entries[].problem] | join(" ")' <<<"$out")" '`b`' "cfg(not(test)) names b"
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(1, 1);
}

#[test]
#[cfg(feature = "slow")]
fn b() {
    assert_eq!(2, 2);
}
EOF2
H2=$(commit "$R" cfg-feature)
out=$(mr "$R" "$B" "$H2"); rc=$?
eq "$rc" 0 "cfg(feature) on a test fn is not an ignore marker"

# item 6 (#27): non-UTF-8 --pr-body is a usage error (guard exceptions removed): no traceback
R=$(mkrepo r6body)
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
H=$(commit "$R" drop-b-body)
ID="R2-$(printf '%s' 'R2tests/a.rsb' | sha1sum | cut -c1-8)"
printf '## Guard exceptions\n- %s: b superseded by a stronger test \377 in a.rs\n' "$ID" > "$T/badbody.md"
out=$(mr "$R" "$B" "$H" --pr-body "$T/badbody.md" 2>&1); rc=$?
lacks "$out" "Traceback" "non-utf8 pr body: no traceback"
eq "$rc" 2 "non-utf8 pr body: usage error exit 2"

# item 7: binary-marked source (-diff attr, or NUL byte) must still show suppressions
R=$(mkrepo r6binattr)
put "$R" .gitattributes <<'EOF2'
*.rs -diff
EOF2
put "$R" src/lib.rs <<'EOF2'
pub fn f() {}
EOF2
B=$(commit "$R" base)
put "$R" src/lib.rs <<'EOF2'
pub fn f() {}
#[allow(dead_code)]
fn g() {}
EOF2
H=$(commit "$R" bare-allow-diff-attr)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "*.rs -diff attr: bare allow still caught"

R=$(mkrepo r6nul)
put "$R" src/lib.rs <<'EOF2'
pub fn f() {}
EOF2
B=$(commit "$R" base)
printf 'pub fn f() {}\n// nul \000 here\n#[allow(dead_code)]\nfn g() {}\n' > "$R/src/lib.rs"
H=$(commit "$R" bare-allow-nul)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "NUL byte in source: bare allow still caught"

# item 9: non-UTF-8 file name is handled, not 'path does not exist'
R=$(mkrepo r6name)
F=$(printf 'src/bad\377.rs')
put "$R" "$F" <<'EOF2'
pub fn f() {}
EOF2
B=$(commit "$R" base)
put "$R" "$F" <<'EOF2'
pub fn f() {}
#[allow(dead_code)]
fn g() {}
EOF2
H=$(commit "$R" bytes-name)
out=$(mr "$R" "$B" "$H" 2>&1); rc=$?
eq "$rc" 1 "non-utf8 file name: suppression caught (exit 1, not 2)"
eq "$(jq -r '.entries[0].check' <<<"$out" 2>/dev/null)" R2 "non-utf8 file name: R2 entry"

# item 10: git C-quoting of control chars in names (\r)
R=$(mkrepo r6cr)
F=$(printf 'src/a\rb.rs')
put "$R" "$F" <<'EOF2'
pub fn f() {}
EOF2
B=$(commit "$R" base)
put "$R" "$F" <<'EOF2'
pub fn f() {}
#[allow(dead_code)]
fn g() {}
EOF2
H=$(commit "$R" cr-name)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$rc" 1 "name with CR: suppression caught"
eq "$(jq -r '.entries[0].file' <<<"$out")" "$F" "name with CR reported verbatim"

# item 8: occurrences of one key in a file each get an entry
R=$(mkrepo r6two_allow)
put "$R" src/lib.rs <<'EOF2'
pub fn f() {}
EOF2
B=$(commit "$R" base)
put "$R" src/lib.rs <<'EOF2'
pub fn f() {}
#[allow(dead_code)]
fn g() {}
#[allow(dead_code)]
fn h() {}
EOF2
H=$(commit "$R" two-allows)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$(jq -r '.entries|length' <<<"$out")" 2 "two bare allows of one lint in one file: two entries"
eq "$(jq -r '[.entries[].id]|unique|length' <<<"$out")" 2 "two entries have distinct ids"
eq "$(jq -r '.entries[0].id' <<<"$out")" "R2-$(printf '%s' 'R2src/lib.rsdead_code' | sha1sum | cut -c1-8)" "first occurrence keeps the plain id"

R=$(mkrepo r6two_exp)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(x, 1);
    assert_eq!(x, 2);
}
EOF2
B=$(commit "$R" base)
put "$R" tests/a.rs <<'EOF2'
#[test]
fn a() {
    assert_eq!(x, 9);
    assert_eq!(x, 8);
}
EOF2
H=$(commit "$R" two-same-lhs)
out=$(mr "$R" "$B" "$H"); rc=$?
eq "$(jq -r '.entries|length' <<<"$out")" 2 "two changed expected values sharing an operand: two entries"
eq "$(jq -r '[.entries[].id]|unique|length' <<<"$out")" 2 "those entries have distinct ids"
eq "$(jq -r '.entries[0].id' <<<"$out")" "R2-$(printf '%s' 'R2tests/a.rsexpected:a|x' | sha1sum | cut -c1-8)" "first expected entry keeps the plain id"

done_tests
