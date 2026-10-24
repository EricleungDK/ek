#!/bin/bash
source "$EK_REPO/.ek/scenarios/lib.sh"
[[ -n $EK_PARENT_DIR && -f $EK_PARENT_DIR/fixtures/pass-run.sh ]] || fail "parent fixtures missing (EK_PARENT_DIR=$EK_PARENT_DIR)"
mk_repo; install_kit
for id in a a/kid; do add_scn $id 0; cp "$EK_PARENT_DIR/fixtures/pass-run.sh" "$SAMPLE/.ek/scenarios/$id/run.sh"; done
add_scn b 1; commit_all s
out=$(python3 "$RUNNER" --repo "$SAMPLE" run a 2>&1); eq "run a rc" $? 0
has run "$out" "PASS a/kid"; has run "$out" "PASS a"; hasnt run "$out" "b"; has run "$out" "2/2"
out=$(python3 "$RUNNER" --repo "$SAMPLE" check 2>&1); eq "check partial rc" $? 1; has check "$out" partial
python3 "$RUNNER" --repo "$SAMPLE" run nope >/dev/null 2>&1; eq "unknown id rc" $? 2
python3 "$RUNNER" --repo "$SAMPLE" run >/dev/null 2>&1; eq "full run rc (b fails)" $? 1
echo "filter ok"
