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

done_tests
