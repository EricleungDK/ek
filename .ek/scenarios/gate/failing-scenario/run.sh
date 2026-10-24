#!/bin/bash
source "$EK_REPO/.ek/scenarios/lib.sh"
mk_repo; install_kit; add_scn red 1; commit_all s
hook SessionStart s3 >/dev/null
echo "a=1" >> "$SAMPLE/app.py"
python3 "$RUNNER" --repo "$SAMPLE" run >/dev/null; eq "runner rc" $? 1
out=$(hook Stop s3); has block "$out" '"decision": "block"'; has block "$out" "last run FAIL"
# plain repo: no scenarios dir
mk_repo; install_kit; hook SessionStart s4 >/dev/null; echo "a=1" >> "$SAMPLE/app.py"
out=$(hook Stop s4); has plain "$out" "Uncommitted changes since session start"; hasnt plain "$out" "Scenarios not green"
echo "failing ok"
