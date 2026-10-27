#!/bin/bash
source "$EK_REPO/.ek/scenarios/lib.sh"
MR="$EK_REPO/scripts/mech-review.py"
R="$PWD/repo"; mkdir -p "$R/tests"; git -C "$R" init -q -b main
printf '#[test]\nfn adds() {\n    assert_eq!(1 + 1, 2);\n}\n\n#[test]\nfn keeps() {\n    assert_eq!(2 + 2, 4);\n}\n' > "$R/tests/math.rs"
git -C "$R" add -A; git -C "$R" commit -qm base; BASE=$(git -C "$R" rev-parse HEAD)

# cheat: delete the test that fails for the agent
printf '#[test]\nfn adds() {\n    assert_eq!(1 + 1, 2);\n}\n' > "$R/tests/math.rs"
git -C "$R" commit -qam cheat; CHEAT=$(git -C "$R" rev-parse HEAD)
out=$(python3 "$MR" r2 --repo "$R" --base "$BASE" --head "$CHEAT" --stack rust --test-paths 'tests/**'); rc=$?
eq "cheat exit" "$rc" 1
eq "cheat check" "$(jq -r '.entries[0].check' <<<"$out")" R2
eq "cheat summary" "$(jq -r .summary <<<"$out")" "fail $CHEAT (1 fail, 0 confirm; ran: R2; skipped: R1 R3 R4)"
eq "cheat class" "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable
eq "cheat file" "$(jq -r '.entries[0].file' <<<"$out")" tests/math.rs
has "cheat id" "$(jq -r '.entries[0].id' <<<"$out")" "R2-"
has "cheat names test" "$(jq -r '.entries[0].problem' <<<"$out")" "keeps"

# clean: branch from base, add a test
git -C "$R" checkout -q -b clean "$BASE"
printf '#[test]\nfn adds() {\n    assert_eq!(1 + 1, 2);\n}\n\n#[test]\nfn keeps() {\n    assert_eq!(2 + 2, 4);\n}\n\n#[test]\nfn more() {\n    assert_eq!(3, 3);\n}\n' > "$R/tests/math.rs"
git -C "$R" commit -qam clean; CLEAN=$(git -C "$R" rev-parse HEAD)
out=$(python3 "$MR" r2 --repo "$R" --base "$BASE" --head "$CLEAN" --stack rust --test-paths 'tests/**'); rc=$?
eq "clean exit" "$rc" 0
eq "clean summary" "$(jq -r .summary <<<"$out")" "pass $CLEAN (0 fail, 0 confirm; ran: R2; skipped: R1 R3 R4)"
echo "mech-review ok"
