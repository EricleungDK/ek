#!/bin/bash
source "$EK_REPO/.ek/scenarios/lib.sh"
MR="$EK_REPO/scripts/mech-review.py"
FX="$EK_REPO/tests/fixtures/mutmut"
# fake mutmut (argv[0] replaced via MECH_TEST_STUB): --version, run (copies the fixture into ./mutants), results, show
STUB="$PWD/fake-mutmut.sh"
cat > "$STUB" <<'SH'
#!/bin/bash
case "$1" in
  --version) echo "mutmut, version 3.8.1"; exit 0 ;;
  run) mkdir -p mutants; cp -r "$MECH_FX/missed/." mutants/; exit 0 ;;
  results) cat mutants/results.txt ;;
  show) cat "mutants/show/$2.txt" ;;
esac
SH
chmod +x "$STUB"
export MECH_FX="$FX"

R="$PWD/repo"; mkdir -p "$R/src/calc" "$R/tests"; git -C "$R" init -q -b main
printf '[project]\nname = "calc"\nversion = "0.0.1"\n' > "$R/pyproject.toml"
printf 'def add(a, b):\n    return a+b\n\n\ndef is_positive(n):\n    return n>0\n\n\ndef mul(a, b):\n    return a * b\n\n\ndef sub(a, b):\n    return a - b\n' > "$R/src/calc/core.py"
printf 'from calc.core import add\n\n\ndef test_add():\n    assert add(0, 0) == 0\n' > "$R/tests/test_core.py"
git -C "$R" add -A; git -C "$R" commit -qm base; BASE=$(git -C "$R" rev-parse HEAD)

# cheat: skip the test that fails for the agent
printf 'import pytest\n\nfrom calc.core import add\n\n\n@pytest.mark.skip(reason="todo")\ndef test_add():\n    assert add(0, 0) == 0\n' > "$R/tests/test_core.py"
git -C "$R" commit -qam cheat; CHEAT=$(git -C "$R" rev-parse HEAD)
out=$(python3 "$MR" r2 --repo "$R" --base "$BASE" --head "$CHEAT" --stack python --test-paths 'tests/**'); rc=$?
eq "skip exit" "$rc" 1
eq "skip check" "$(jq -r '.entries[0].check' <<<"$out")" R2
eq "skip class" "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable
eq "skip file" "$(jq -r '.entries[0].file' <<<"$out")" tests/test_core.py
has "skip names test" "$(jq -r '.entries[0].problem' <<<"$out")" "test_add"
eq "skip summary" "$(jq -r .summary <<<"$out")" "fail $CHEAT (1 fail, 0 confirm; ran: R2; skipped: R1 R3 R4)"

# clean: from base, add a passing test
git -C "$R" checkout -q -b clean "$BASE"
printf 'from calc.core import add, mul\n\n\ndef test_add():\n    assert add(0, 0) == 0\n\n\ndef test_mul():\n    assert mul(2, 3) == 6\n' > "$R/tests/test_core.py"
git -C "$R" commit -qam clean; CLEAN=$(git -C "$R" rev-parse HEAD)
out=$(python3 "$MR" r2 --repo "$R" --base "$BASE" --head "$CLEAN" --stack python --test-paths 'tests/**'); rc=$?
eq "clean exit" "$rc" 0
eq "clean summary" "$(jq -r .summary <<<"$out")" "pass $CLEAN (0 fail, 0 confirm; ran: R2; skipped: R1 R3 R4)"

# mutation: head changes add and is_positive (the real fixture head); mutmut replays the missed fixture
git -C "$R" checkout -q -b mut "$BASE"
cp "$EK_REPO/tests/fixtures/mutmut/head/src/calc/core.py" "$R/src/calc/core.py"
git -C "$R" commit -qam mut; MUT=$(git -C "$R" rev-parse HEAD)
out=$(MECH_TEST_STUB="$STUB" python3 "$MR" mutants --repo "$R" --base "$BASE" --head "$MUT" --stack python --test-paths 'tests/**' --mutants-cmd mutmut); rc=$?
eq "mutmut exit" "$rc" 1
eq "mutmut entries" "$(jq -r '[.entries[] | select(.check=="R3")] | length' <<<"$out")" 3
eq "mutmut lines" "$(jq -r '[.entries[].line] | sort | map(tostring) | join(",")' <<<"$out")" "2,6,6"
hasnt "sub outside diff" "$(jq -r '[.entries[].problem] | join(" ")' <<<"$out")" "core.py:14"
eq "mutmut summary" "$(jq -r .summary <<<"$out")" "fail $MUT (3 fail, 0 confirm; ran: R3; skipped: R1 R2 R4)"

# plan: a python production change runs the mutants job over 4 shards
out=$(python3 "$MR" plan --repo "$R" --base "$BASE" --head "$MUT" --stack python --test-paths 'tests/**' --shards 4)
eq "plan" "$(jq -c '{run,count,shards}' <<<"$out")" '{"run":true,"count":4,"shards":[0,1,2,3]}'
echo "mech-review python ok"
