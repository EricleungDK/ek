#!/bin/bash
source "$EK_REPO/.ek/scenarios/lib.sh"
source "$EK_PARENT_DIR/fixtures/helpers.sh"
R="$PWD/rust"; rust_repo "$R"
caller "$R" <<<"${GOOD_WITH/test-paths: crates\/app\/tests\/\*\*/test-paths: tests/**}"
grep -q 'test-paths: tests/\*\*' "$R/.github/workflows/mech-review.yml" || fail "fixture: caller test-paths not rewritten"
out=$(doctor --repo "$R"); rc=$?
eq "test-paths exit" "$rc" 1
has "test-paths fix" "$(jq -r '[.entries[].hint]|join("; ")' <<<"$out")" "set test-paths: crates/app/tests/**"
echo "caller-test-paths ok"
