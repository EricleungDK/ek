#!/bin/bash
source "$EK_REPO/.ek/scenarios/lib.sh"
[[ -f $EK_PARENT_DIR/SCENARIO.md ]] || fail "no EK_PARENT_DIR"
mk_repo; install_kit
add_scn hang 0; printf '#!/bin/bash\nsleep 30\n' > "$SAMPLE/.ek/scenarios/hang/run.sh"; commit_all s
t0=$SECONDS
out=$(EK_SCENARIO_TIMEOUT=1 python3 "$RUNNER" --repo "$SAMPLE" run 2>&1); rc=$?
eq "rc" $rc 1; has run "$out" "FAIL hang: timeout after 1s"
(( SECONDS - t0 < 15 )) || fail "took $((SECONDS - t0))s"
echo "timeout ok"
