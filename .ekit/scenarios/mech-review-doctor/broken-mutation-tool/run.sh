#!/bin/bash
source "$EKIT_REPO/.ekit/scenarios/lib.sh"
source "$EKIT_PARENT_DIR/fixtures/helpers.sh"
R="$PWD/rust"; rust_repo "$R"; caller "$R" <<<"$GOOD_WITH"
out=$(STUB_TOOL=broken doctor --repo "$R"); rc=$?
eq "tests still ran" "$(jq -r .trial.tests <<<"$out")" pass
[[ "$(jq -r .trial.mutation_tool <<<"$out")" != present ]] || fail "a tool that exits 1 reported present: $(jq -c .trial <<<"$out")"
eq "broken tool exit" "$rc" 1
has "broken tool entry" "$(jq -r '[.entries[].problem]|join("; ")' <<<"$out")" "mutants"
echo "broken-mutation-tool ok"
