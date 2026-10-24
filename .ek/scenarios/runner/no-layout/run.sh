#!/bin/bash
source "$EK_REPO/.ek/scenarios/lib.sh"
mk_repo; install_kit
out=$(python3 "$RUNNER" --repo "$SAMPLE" run 2>&1); eq "run rc" $? 2
has run "$out" ".ek/scenarios/<slug>/SCENARIO.md + run.sh"; hasnt run "$out" Traceback
out=$(python3 "$RUNNER" --repo "$SAMPLE" check 2>&1); eq "check rc" $? 2; has check "$out" ".ek/scenarios/<slug>"
out=$(python3 "$RUNNER" --repo "$SAMPLE" bogus 2>&1); eq "bad cmd rc" $? 2; has usage "$out" usage
echo "no-layout ok"
