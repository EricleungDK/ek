#!/bin/bash
source "$EKIT_REPO/.ekit/scenarios/lib.sh"
mk_repo; install_kit; add_scn ok 0; commit_all s
hook SessionStart sess1 >/dev/null || fail "session start hook failed"
echo "u=1" >> "$SAMPLE/app.py"; eq "unarmed -> allow" "$(hook Stop sess1)" ""; git -C "$SAMPLE" checkout -q app.py
arm sess1 || fail "arm hook failed"
eq "no work -> allow" "$(hook Stop sess1)" ""
echo "x=1" >> "$SAMPLE/app.py"
out=$(hook Stop sess1)
has block "$out" '"decision": "block"'; has block "$out" "Scenarios not green"; has block "$out" "scenarios.py"
eq "loop guard" "$(hook Stop sess1 true)" ""
python3 "$RUNNER" --repo "$SAMPLE" run >/dev/null || fail "runner not green"
eq "fresh PASS -> allow" "$(hook Stop sess1)" ""
eq "SubagentStop allow" "$(hook SubagentStop sess1)" ""
echo "gate ok"
