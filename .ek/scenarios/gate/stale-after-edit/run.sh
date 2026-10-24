#!/bin/bash
source "$EK_REPO/.ek/scenarios/lib.sh"
[[ -f $EK_PARENT_DIR/SCENARIO.md ]] || fail "no EK_PARENT_DIR"
mk_repo; install_kit; add_scn ok 0; commit_all s
hook SessionStart s2 >/dev/null
echo "a=1" >> "$SAMPLE/app.py"
python3 "$RUNNER" --repo "$SAMPLE" run >/dev/null || fail "not green"
eq "fresh -> allow" "$(hook Stop s2)" ""
echo "b=2" >> "$SAMPLE/app.py"
out=$(hook Stop s2); has block "$out" '"decision": "block"'; has block "$out" stale
python3 "$RUNNER" --repo "$SAMPLE" run >/dev/null
eq "re-run -> allow" "$(hook Stop s2)" ""
echo "stale ok"
