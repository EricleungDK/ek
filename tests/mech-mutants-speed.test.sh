#!/bin/bash
# R3 rust builds: the toolchain action exports CARGO_INCREMENTAL=0, so every mutant rebuilt the whole crate from
# scratch. The baseline and shard steps turn incremental builds back on and drop debug info (each mutant relinks
# every test binary). Same tests, same verdicts: only build time changes.
source "$(dirname "$0")/lib.sh"
WF="$ROOT/.github/workflows/mech-review.yml"
# step <name>: the lines of the step whose `- name:` is <name>, up to the next step
step() { awk -v n="      - name: $1" '$0 == n {on=1; print; next} on && /^      - name: / {exit} on && /^  [a-z]/ {exit} on {print}' "$WF"; }
for s in "R3 baseline (once; shard count, derived timeout)" "R3 mutation on the diff (shard)"; do
  body=$(step "$s")
  [[ -n $body ]] && ok "$s: step found" || fail "$s: step found"
  has "$body" 'export CARGO_INCREMENTAL=1' "$s: incremental builds on (overrides the toolchain action's 0)"
  has "$body" 'export CARGO_PROFILE_DEV_DEBUG=0 CARGO_PROFILE_TEST_DEBUG=0' "$s: no debug info"
  has "$body" 'if [ "$STACK" = "rust" ]; then' "$s: rust only"
done
done_tests
