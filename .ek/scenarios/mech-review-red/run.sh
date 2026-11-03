#!/bin/bash
source "$EK_REPO/.ek/scenarios/lib.sh"
MR="$EK_REPO/scripts/mech-review.py"
# fake toolchain: prints the cargo result for the test named last in argv, from ./outcomes in the checkout; R1's checkout
# (the base's code with the PR's test files on top) has no ./outcomes and reads tests/outcomes.base
STUB="$PWD/fake-cargo.sh"
cat > "$STUB" <<'SH'
#!/bin/bash
name="${*: -1}"
f=outcomes; [[ -f $f ]] || f=tests/outcomes.base
o=$(awk -v n="$name" '$1 == n { print $2 }' "$f" 2>/dev/null)
case "${o:-pass}" in
  pass) printf 'test result: ok. 1 passed; 0 failed\n'; exit 0 ;;
  fail) printf 'test result: FAILED. 0 passed; 1 failed\n'; exit 101 ;;
esac
SH
chmod +x "$STUB"
commit() { git -C "$R" add -A; git -C "$R" commit -qm "$1"; git -C "$R" rev-parse HEAD; }
TESTS_BASE='#[test]
fn adds() {
    assert_eq!(2, 2);
}'
TESTS_RED="$TESTS_BASE"'

#[test]
fn fresh() {
    assert_eq!(add(1, 2), 3);
}'

R="$PWD/repo"; mkdir -p "$R/tests" "$R/src"; git -C "$R" init -q -b main
printf 'pub fn add(a: i32, b: i32) -> i32 { a + b }\n' > "$R/src/lib.rs"
printf '%s\n' "$TESTS_BASE" > "$R/tests/a.rs"
BASE=$(commit base)

# agent branch: a test commit adds fresh, which fails on the base's code; head fixes the production code
git -C "$R" checkout -q -b agent/x
printf '%s\n' "$TESTS_RED" > "$R/tests/a.rs"; printf 'fresh fail\n' > "$R/outcomes"; cp "$R/outcomes" "$R/tests/outcomes.base"; RED=$(commit "test(red): fresh")
printf 'pub fn add(a: i32, b: i32) -> i32 { a + b } // fixed\n' > "$R/src/lib.rs"
printf 'fresh pass\nadds pass\n' > "$R/outcomes"; HEAD_SHA=$(commit "feat: fix")
run() { MECH_TEST_STUB="$STUB" python3 -I "$MR" red --repo "$R" --base "$BASE" --head "$HEAD_SHA" --head-branch agent/x --stack rust --test-paths 'tests/**' "$@"; }

out=$(run); rc=$?
eq "red fails, head passes: exit" "$rc" 0
eq "red fails, head passes: R1" "$(jq -r .checks.R1.status <<<"$out")" pass
eq "red fails, head passes: summary" "$(jq -r .summary <<<"$out")" "pass $HEAD_SHA (0 fail, 0 confirm; ran: R1 R4; skipped: R2 R3)"

# the same test, but fresh passes on the base's code too: it does not catch the change
git -C "$R" checkout -q -b pass-red "$BASE"
printf '%s\n' "$TESTS_RED" > "$R/tests/a.rs"; printf 'fresh pass\n' > "$R/outcomes"; cp "$R/outcomes" "$R/tests/outcomes.base"; PASS_RED=$(commit "test(red): fresh")
printf 'pub fn add(a: i32, b: i32) -> i32 { a + b } // fixed\n' > "$R/src/lib.rs"; printf 'fresh pass\nadds pass\n' > "$R/outcomes"; PASS_HEAD=$(commit "feat: fix")
out=$(run --base "$BASE" --head "$PASS_HEAD" --head-branch agent/x); rc=$?
eq "red passes: exit" "$rc" 1
has "red passes: entry" "$(jq -r '.entries[0].problem' <<<"$out")" "pass on the base's code too"
eq "red passes: class" "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable

# no toolchain on the same branch: n/a, named in the summary, never all pass
out=$(env -u MECH_TEST_STUB python3 -I "$MR" red --repo "$R" --base "$BASE" --head "$PASS_HEAD" --head-branch agent/x --stack rust --test-paths 'tests/**' --test-cmd "ek-no-such-toolchain test"); rc=$?
eq "no toolchain: R1" "$(jq -r .checks.R1.status <<<"$out")" n/a
eq "no toolchain: R4" "$(jq -r .checks.R4.status <<<"$out")" n/a
has "no toolchain: summary names n/a" "$(jq -r .summary <<<"$out")" "n/a: R1 R4"
hasnt "no toolchain: never all pass" "$(jq -r .summary <<<"$out")" "all pass"
eq "caller checkout untouched" "$(git -C "$R" status --porcelain | wc -l)" 0
echo "mech-review-red ok"
