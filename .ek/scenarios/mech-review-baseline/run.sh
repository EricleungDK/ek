#!/bin/bash
source "$EK_REPO/.ek/scenarios/lib.sh"
MR="$EK_REPO/scripts/mech-review.py"
FX="$EK_REPO/tests/fixtures/mutants"
# fake cargo-mutants (argv[0] replaced via MECH_TEST_STUB): --version; --list --json (the fixture list); a run with
# --output DIR (a fixture mutants.out, MUT_FIXTURE; {k} = shard index); MUT_RC the exit code; MUT_HANG=1 sleeps.
STUB="$PWD/fake-cargo-mutants.sh"
cat > "$STUB" <<'FAKE'
#!/bin/bash
if [[ "$1" == mutants && "$2" == --version ]]; then echo "cargo-mutants 27.1.0"; exit 0; fi
out=""; shard=""; prev=""; list=""
for a in "$@"; do
  case "$prev" in -o|--output) out="$a" ;; --shard) shard="$a" ;; esac
  [[ "$a" == --list ]] && list=1
  prev="$a"
done
[[ -n "${MUT_LOG-}" ]] && echo "$*" >> "$MUT_LOG"
if [[ -n "$list" ]]; then cat "$MECH_FX/${MUT_LIST:-list-15.json}"; exit 0; fi
k=${shard%%/*}
if [[ -n "${MUT_FIXTURE-}" && -n "$out" ]]; then
  fx="${MUT_FIXTURE//\{k\}/$k}"
  mkdir -p "$out/mutants.out"; cp -r "$MECH_FX/$fx/." "$out/mutants.out/"
fi
if [[ -n "${MUT_HANG-}" ]]; then sleep 30; fi
exit "${MUT_RC:-0}"
FAKE
chmod +x "$STUB"
export MECH_FX="$FX"

R="$PWD/repo"; mkdir -p "$R/src" "$R/tests"; git -C "$R" init -q -b main
printf 'pub fn add(a: i32, b: i32) -> i32 { a + b }\n' > "$R/src/lib.rs"
printf '#[test]\nfn adds() {\n    assert_eq!(add(1, 2), 3);\n}\n' > "$R/tests/a.rs"
printf '[package]\nname = "x"\nversion = "0.1.0"\n' > "$R/Cargo.toml"
git -C "$R" add -A; git -C "$R" commit -qm base; B=$(git -C "$R" rev-parse HEAD)
printf 'pub fn add(a: i32, b: i32) -> i32 { a + b } // fixed\n' > "$R/src/lib.rs"
git -C "$R" add -A; git -C "$R" commit -qm head; H=$(git -C "$R" rev-parse HEAD)
bl() { MECH_TEST_STUB="$STUB" python3 -I "$MR" baseline --repo "$R" --base "$B" --head "$H" --stack rust --test-paths 'tests/**' "$@"; }
mut() { MECH_TEST_STUB="$STUB" python3 -I "$MR" mutants --repo "$R" --base "$B" --head "$H" --stack rust --test-paths 'tests/**' "$@"; }

# 2. baseline once: run, 4 shards, derived timeout (20 s floor), baseline-only run (one mutant, build killed at 0 s)
: > "$PWD/calls.log"
BL="$PWD/bl-ok.json"
out=$(MUT_LOG="$PWD/calls.log" MUT_FIXTURE=baseline-ok MUT_RC=3 bl --shards 4); rc=$?
eq "baseline exit" "$rc" 0
eq "baseline ok" "$(jq -c '{run,count,mutants,timeout}' <<<"$out")" '{"run":true,"count":4,"mutants":15,"timeout":20}'
eq "baseline R3 left to shards" "$(jq -r .checks.R3.status <<<"$out")" skipped
has "baseline lists first" "$(cat "$PWD/calls.log")" "--list --json"
has "baseline kills mutant builds at 0 s" "$(cat "$PWD/calls.log")" "--build-timeout 0"
hasnt "baseline has no --timeout" "$(cat "$PWD/calls.log")" " --timeout"
printf '%s\n' "$out" > "$BL"

# 3. shard with a set timeout: baseline skipped, explicit timeout, round-robin
: > "$PWD/calls.log"
MUT_LOG="$PWD/calls.log" MUT_FIXTURE=caught MUT_RC=0 mut --shard 1/2 --mutant-timeout 30 >/dev/null
has "shard skips the baseline" "$(cat "$PWD/calls.log")" "--baseline skip"
has "shard explicit timeout" "$(cat "$PWD/calls.log")" "--timeout 30"
has "shard round-robin" "$(cat "$PWD/calls.log")" "--sharding round-robin"

# 4. shards 0/2 and 1/2 merge with the baseline: one result, baseline seconds once, no CI entry
S0="$PWD/shard0.json"; S1="$PWD/shard1.json"
MUT_FIXTURE=missed MUT_RC=2 mut --shard 0/2 > "$S0"
MUT_FIXTURE=caught MUT_RC=0 mut --shard 1/2 > "$S1"
out=$(python3 -I "$MR" merge --repo "$R" --base "$B" --head "$H" --stack rust --baseline "$BL" --shards 2 --envelope 0="$S0" --envelope 1="$S1"); rc=$?
eq "merge exit" "$rc" 1
eq "merge R3 entries" "$(jq -r '[.entries[] | select(.check=="R3")] | length' <<<"$out")" 11
eq "merge no CI entry" "$(jq -r '[.entries[] | select(.check=="CI")] | length' <<<"$out")" 0
eq "merge baseline seconds once" "$(jq -r .checks.R3.timing.baseline_test_s <<<"$out")" "$(jq -r .checks.R3.timing.baseline_test_s "$BL")"

# 5. baseline fails at head: its R3 is the result, no shard ran, no CI entry for them
out=$(MUT_FIXTURE=baseline-failure MUT_RC=4 bl 2>/dev/null); rc=$?
eq "baseline fail exit" "$rc" 0
eq "baseline fail run" "$(jq -r .run <<<"$out")" false
BF="$PWD/bl-fail.json"; printf '%s\n' "$out" > "$BF"
out=$(python3 -I "$MR" merge --repo "$R" --base "$B" --head "$H" --stack rust --baseline "$BF" --shards 0); rc=$?
eq "baseline fail merge exit" "$rc" 1
eq "baseline fail merge R3" "$(jq -r .checks.R3.status <<<"$out")" fail
eq "baseline fail merge no CI" "$(jq -r '[.entries[] | select(.check=="CI")] | length' <<<"$out")" 0

# 6. baseline timed out by the budget before it finished: n/a, never fail, no shard
out=$(MUT_HANG=1 bl --mutation-budget 0.02); rc=$?
eq "baseline timeout R3" "$(jq -r .checks.R3.status <<<"$out")" n/a
has "baseline timeout names the budget" "$(jq -r .checks.R3.note <<<"$out")" "mutation-budget"
eq "baseline timeout no shards" "$(jq -r .run <<<"$out")" false

# 7. no mutants in the diff: pass, no shards
out=$(MUT_LIST=list-none.json bl); rc=$?
eq "no mutants" "$(jq -c '{run,count,mutants,st:.checks.R3.status}' <<<"$out")" '{"run":false,"count":0,"mutants":0,"st":"pass"}'

# 8. no baseline result at all: R3 fails, the CI entry names the baseline job
out=$(python3 -I "$MR" merge --repo "$R" --base "$B" --head "$H" --stack rust --baseline-reason "no JSON from the baseline job" --shards 2); rc=$?
eq "no baseline result exit" "$rc" 1
has "no baseline names the job" "$(jq -r '[.entries[] | select(.check=="CI")][0].problem' <<<"$out")" "baseline job produced no result"

# 9. docs-only change: plan says no R3, so the baseline step is not reached
DR="$PWD/docs-repo"; mkdir -p "$DR/src" "$DR/tests"; git -C "$DR" init -q -b main
printf 'pub fn add(a: i32, b: i32) -> i32 { a + b }\n' > "$DR/src/lib.rs"; printf '#[test]\nfn adds() {}\n' > "$DR/tests/a.rs"
git -C "$DR" add -A; git -C "$DR" commit -qm base; DB=$(git -C "$DR" rev-parse HEAD)
printf 'notes\n' > "$DR/README.md"; git -C "$DR" add -A; git -C "$DR" commit -qm docs; DH=$(git -C "$DR" rev-parse HEAD)
out=$(python3 -I "$MR" plan --repo "$DR" --base "$DB" --head "$DH" --stack rust --test-paths 'tests/**'); rc=$?
eq "docs-only plan run" "$(jq -r .run <<<"$out")" false

eq "caller checkout untouched" "$(git -C "$R" status --porcelain | wc -l)" 0
echo "mech-review-baseline ok"
