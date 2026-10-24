#!/bin/bash
source "$EK_REPO/.ek/scenarios/lib.sh"
mk_repo; install_kit
add_scn hello 0; add_scn bad 1; commit_all s
out=$(python3 "$RUNNER" --repo "$SAMPLE" run 2>&1); rc=$?
eq "run rc with failing scn" $rc 1
has run "$out" "PASS hello"; has run "$out" "FAIL bad"
python3 "$RUNNER" --repo "$SAMPLE" check >/dev/null; eq "check after fail" $? 1
rm -rf "$SAMPLE/.ek/scenarios/bad"; commit_all drop
h1=$(python3 "$RUNNER" --repo "$SAMPLE" tree-hash)
out=$(python3 "$RUNNER" --repo "$SAMPLE" run 2>&1); eq "run rc green" $? 0
has run "$out" "PASS: 1/1"
python3 "$RUNNER" --repo "$SAMPLE" check >/dev/null; eq "check fresh" $? 0
echo "x=1" >> "$SAMPLE/app.py"
out=$(python3 "$RUNNER" --repo "$SAMPLE" check 2>&1); eq "check stale rc" $? 1; has check "$out" stale
h2=$(python3 "$RUNNER" --repo "$SAMPLE" tree-hash)
[[ -n $h1 && $h1 != "$h2" ]] || fail "tree-hash unchanged by edit"
echo "runner ok"
