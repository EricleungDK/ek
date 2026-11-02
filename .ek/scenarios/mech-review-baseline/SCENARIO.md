# mech-review baseline once (R3, #46): one baseline step, shards skip it, derived timeout, empty shards never run

- story: As a repo owner I run the R3 baseline once per PR and the mutants shards after it. The unmutated tree is measured once, shards skip it and take a per-mutant timeout derived from it, no shard runs empty, and a baseline that fails or times out is the R3 result with no shard run.
- covers: `baseline` run/count/timeout (20 s floor); a baseline timeout is n/a (no shard runs); a baseline failure is fail (no shard runs); no mutants gives pass with no shards; a shard run skips the baseline with an explicit `--timeout`; `merge --baseline` merges shards and adds the baseline seconds once; `merge` with no baseline result is a CI fail that names the baseline job
- steps:
  1. Repo on base with `src/lib.rs` and `tests/a.rs`; head changes `src/lib.rs`. The cargo-mutants stub (MECH_TEST_STUB) answers `--version`, `--list --json` (a fixture list of 15 mutants) and a run with `--output DIR` (a fixture `mutants.out`, exit code from MUT_RC).
  2. Run `scripts/mech-review.py baseline --shards 4` with the `baseline-ok` fixture (exit 3, a mutant build killed at 0 s). Expect exit 0, `run` true, `count` 4, `mutants` 15, `timeout` 20, R3 skipped. The stub log shows `--list --json`, `--build-timeout 0`, `--shard 0/15`, and no `--timeout`.
  3. Run `mutants --shard 1/2 --mutant-timeout 30` on the `caught` fixture. Expect the argv to hold `--baseline skip`, `--timeout 30`, `--sharding round-robin`, `--shard 1/2`.
  4. Shards 0/2 (`missed` fixture, exit 2) and 1/2 (`caught`, exit 0), then `merge --baseline <step 2 output> --shards 2`. Expect exit 1, 11 R3 entries, no CI entry, and `checks.R3.timing.baseline_test_s` equal to the baseline's (once).
  5. A baseline run that fails (`baseline-failure` fixture, exit 4): expect `run` false, R3 fail with one agent-fixable entry, and `merge --baseline` gives summary `fail <head> (1 fail, ...)` with no CI entry (no shard was run).
  6. A baseline that the budget kills before it finishes (`MUT_HANG=1`, budget 0.02 min): expect R3 n/a with a note that says timed out and names mutation-budget, and `run` false.
  7. `list-none.json` (no mutants in the diff): expect `run` false, `count` 0, R3 pass.
  8. `merge --baseline-reason "..."` with no baseline result: expect exit 1 and a CI entry that names the baseline job.
  9. `plan` on a docs-only change: expect `run` false, and the stub never invoked by the baseline step.
- expected: exit codes and summaries as above; the caller checkout is untouched (HEAD and status unchanged).
