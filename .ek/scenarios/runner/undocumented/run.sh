#!/bin/bash
source "$EK_REPO/.ek/scenarios/lib.sh"
mk_repo; install_kit
add_scn quick 0 0; printf '#!/bin/bash\ntouch "$PWD/RAN"\n' > "$SAMPLE/.ek/scenarios/quick/run.sh"; commit_all s
out=$(python3 "$RUNNER" --repo "$SAMPLE" run 2>&1); eq "rc" $? 1
has run "$out" "FAIL quick"; has run "$out" "document it"
python3 "$RUNNER" --repo "$SAMPLE" check >/dev/null; eq "check" $? 1
echo "undocumented ok"
