#!/bin/bash
source "$EK_REPO/.ek/scenarios/lib.sh"
MR="$EK_REPO/scripts/mech-review.py"
FX="$EK_REPO/tests/fixtures/mutants"
# fake cargo-mutants (argv[0] replaced via MECH_TEST_STUB): `mutants --version`, or a run with --output DIR and --shard k/n.
# MUT_FIXTURE names a real cargo-mutants 27.1.0 output dir under tests/fixtures/mutants ({k} = shard index);
# MUT_RC is the exit code; MUT_HANG=1 sleeps so the budget kills the run.
STUB="$PWD/fake-cargo-mutants.sh"
cat > "$STUB" <<'SH'
#!/bin/bash
if [[ "$1" == mutants && "$2" == --version ]]; then echo "cargo-mutants 27.1.0"; exit 0; fi
out=""; shard=""; prev=""
for a in "$@"; do
  case "$prev" in -o|--output) out="$a" ;; --shard) shard="$a" ;; esac
  prev="$a"
done
k=${shard%%/*}
if [[ -n "${MUT_FIXTURE-}" && -n "$out" ]]; then
  fx="${MUT_FIXTURE//\{k\}/$k}"
  mkdir -p "$out/mutants.out"; cp -r "$MECH_FX/$fx/." "$out/mutants.out/"
fi
[[ -n "${MUT_LOG-}" ]] && echo "$*" >> "$MUT_LOG"
if [[ -n "${MUT_HANG-}" ]]; then sleep 30; fi
exit "${MUT_RC:-0}"
SH
chmod +x "$STUB"
export MECH_FX="$FX"

# repo: base and a head that changes src/lib.rs (production) or only tests
R="$PWD/repo"; mkdir -p "$R/src" "$R/tests"; git -C "$R" init -q -b main
printf 'pub fn add(a: i32, b: i32) -> i32 { a + b }\n' > "$R/src/lib.rs"
printf '#[test]\nfn adds() {\n    assert_eq!(add(1, 2), 3);\n}\n' > "$R/tests/a.rs"
git -C "$R" add -A; git -C "$R" commit -qm base; B=$(git -C "$R" rev-parse HEAD)
printf 'pub fn add(a: i32, b: i32) -> i32 { a + b } // fixed\n' > "$R/src/lib.rs"
git -C "$R" add -A; git -C "$R" commit -qm head; H=$(git -C "$R" rev-parse HEAD)
mut() { MECH_TEST_STUB="$STUB" python3 -I "$MR" mutants --repo "$R" --base "$B" --head "$H" --stack rust --test-paths 'tests/**' "$@"; }

# 1. MISSED: fail, exit 1, one R3 entry per missed mutant
out=$(MUT_FIXTURE=missed MUT_RC=2 mut); rc=$?
eq "missed exit" "$rc" 1
eq "missed R3" "$(jq -r .checks.R3.status <<<"$out")" fail
eq "missed entries" "$(jq -r '[.entries[] | select(.check=="R3")] | length' <<<"$out")" 11
eq "missed class" "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable
has "missed names the mutant" "$(jq -r '.entries[0].problem' <<<"$out")" "MISSED mutant src/lib.rs:2:11: replace + with - in add"
eq "missed summary" "$(jq -r .summary <<<"$out")" "fail $H (11 fail, 0 confirm; ran: R3; skipped: R1 R2 R4)"

# 2. budget hit, nothing missed yet: partial 7/15, exit 0, never all pass
out=$(MUT_FIXTURE=partial MUT_RC=0 MUT_HANG=1 mut --mutation-budget 0.02); rc=$?
eq "partial exit" "$rc" 0
eq "partial R3" "$(jq -r .checks.R3.status <<<"$out")" partial
eq "partial summary" "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 1 confirm; ran: R3; partial: R3 (7/15); skipped: R1 R2 R4)"
hasnt "partial never all pass" "$(jq -r .summary <<<"$out")" "all pass"

# 3. no cargo-mutants: n/a (env), named, never pass
out=$(env -u MECH_TEST_STUB python3 -I "$MR" mutants --repo "$R" --base "$B" --head "$H" --stack rust --test-paths 'tests/**' --mutants-cmd "ek-no-such-cargo mutants"); rc=$?
eq "n/a exit" "$rc" 0
eq "n/a R3" "$(jq -r .checks.R3.status <<<"$out")" n/a
eq "n/a summary" "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 0 confirm; ran: none; skipped: R1 R2 R4; n/a: R3)"
hasnt "n/a never all pass" "$(jq -r .summary <<<"$out")" "all pass"

# 4. docs-only head: R3 skipped with the reason, cargo-mutants never runs
DR="$PWD/docs-repo"; mkdir -p "$DR/src" "$DR/tests"; git -C "$DR" init -q -b main
printf 'pub fn add(a: i32, b: i32) -> i32 { a + b }\n' > "$DR/src/lib.rs"; printf '#[test]\nfn adds() {}\n' > "$DR/tests/a.rs"
git -C "$DR" add -A; git -C "$DR" commit -qm base; DB=$(git -C "$DR" rev-parse HEAD)
printf '#[test]\nfn adds() {\n    assert_eq!(add(1, 2), 3);\n}\n' > "$DR/tests/a.rs"
git -C "$DR" add -A; git -C "$DR" commit -qm docs; DH=$(git -C "$DR" rev-parse HEAD)
: > "$PWD/calls.log"
out=$(MUT_LOG="$PWD/calls.log" MECH_TEST_STUB="$STUB" MUT_FIXTURE=missed MUT_RC=2 python3 -I "$MR" mutants --repo "$DR" --base "$DB" --head "$DH" --stack rust --test-paths 'tests/**'); rc=$?
eq "skipped: cargo-mutants never invoked" "$(wc -l < "$PWD/calls.log" | tr -d ' ')" 0
eq "skipped exit" "$rc" 0
eq "skipped R3" "$(jq -r .checks.R3.status <<<"$out")" skipped
has "skipped reason" "$(jq -r .checks.R3.note <<<"$out")" "no production file changed"
eq "skipped summary" "$(jq -r .summary <<<"$out")" "pass $DH (0 fail, 0 confirm; ran: none; skipped: R1 R2 R3 R4)"

# 5. shards: 0/2 and 1/2 run separately, merged into one result; a missing shard is a CI fail that keeps the other
S0="$PWD/shard0.json"; S1="$PWD/shard1.json"
MUT_FIXTURE='shard-{k}-of-2' MUT_RC=2 mut --shard 0/2 > "$S0"
MUT_FIXTURE='shard-{k}-of-2' MUT_RC=2 mut --shard 1/2 > "$S1"
out=$(python3 -I "$MR" merge --repo "$R" --base "$B" --head "$H" --stack rust --shards 2 --envelope 0="$S0" --envelope 1="$S1"); rc=$?
eq "merge exit" "$rc" 1
eq "merge summary" "$(jq -r .summary <<<"$out")" "fail $H (11 fail, 0 confirm; ran: R3; skipped: R1 R2 R4)"
out=$(python3 -I "$MR" merge --repo "$R" --base "$B" --head "$H" --stack rust --shards 2 --envelope 0="$S0")
has "merge missing shard names it" "$(jq -r '[.entries[] | select(.check=="CI")][0].problem' <<<"$out")" "shard 1/2"
eq "merge missing shard keeps the other" "$(jq -r '[.entries[] | select(.check=="R3")] | length' <<<"$out")" 3

eq "caller checkout untouched" "$(git -C "$R" status --porcelain | wc -l)" 0
echo "mech-review-mutants ok"
