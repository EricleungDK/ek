# mech-review mutants (R3): MISSED fails, budget hit is partial, no tool is n/a, no prod change is skipped, shards merge

- story: As a repo owner I run `mech-review.py mutants` on a PR and trust R3: a mutant the tests miss fails with the mutant named, a budget hit with nothing missed is partial and does not block, a missing cargo-mutants says n/a (env), a docs-only change skips R3, and two shards merge into one result.
- covers: R3 MISSED (fail, exit 1); R3 partial 7/15 (exit 0, summary names partial); R3 n/a (env) when the tool is absent; R3 skipped with no production change; `merge` of two shards (11 entries, one R3 fail)
- steps:
  1. Repo on base with `src/lib.rs` and `tests/a.rs`; agent-style head changes `src/lib.rs`. The cargo-mutants stub (MECH_TEST_STUB) copies a fixture `mutants.out` (real cargo-mutants 27.1.0 output) and exits with a given code.
  2. Run `scripts/mech-review.py mutants --base --head --stack rust --test-paths 'tests/**'` with the stub replaying the `missed` fixture (exit 2). Expect exit 1, R3 fail, 11 R3 entries, summary `fail <head> (11 fail, 0 confirm; ran: R3; skipped: R1 R2 R4)`.
  3. Replay the `partial` fixture with the stub hanging and a 0.02 minute budget. Expect exit 0, R3 partial with note `7/15 tested`, summary `pass <head> (0 fail, 1 confirm; ran: R3; partial: R3 (7/15); skipped: R1 R2 R4)`.
  4. Run with `--mutants-cmd "ekit-no-such-cargo mutants"`. Expect exit 0, R3 n/a, summary `... ; ran: none; skipped: R1 R2 R4; n/a: R3)`, never `all pass`.
  5. Docs-only head (no production file). Expect R3 skipped with `no production file changed`, and the stub never invoked.
  6. Shards: run the stub with `--shard 0/2` (fixture `shard-0-of-2`) and `--shard 1/2` (fixture `shard-1-of-2`), then `merge --shards 2`. Expect exit 1 and summary `fail <head> (11 fail, 0 confirm; ran: R3; skipped: R1 R2 R4)`; with shard 1 missing, a CI entry names `shard 1/2`.
- expected: exit codes and summaries as above; the caller checkout is untouched (HEAD and status unchanged).
