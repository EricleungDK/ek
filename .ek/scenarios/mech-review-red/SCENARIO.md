# mech-review red-first: a red that passes is caught, a red that fails passes, no toolchain is n/a, not pass

- story: As a repo owner I run `mech-review.py red` on an agent branch and trust R1 and R4: a test that passes before the fix is a fail, a test that fails there is a pass, and a missing toolchain says n/a.
- covers: R1 the new test passes on the base's code too (fail); R1 red fails and head passes (pass, R4 pass); toolchain absent (R1 and R4 n/a, summary names n/a, never all pass)
- steps:
  1. Repo on base with `tests/a.rs` (test `adds`) and `src/lib.rs`. Agent branch: a commit adding test `fresh` (it fails on the base's code), then a head commit changing `src/lib.rs`. The stub runner (`MECH_TEST_STUB`) reads `outcomes` in the checkout: `fresh fail` at red, `fresh pass` at head.
  2. Run `scripts/mech-review.py red --base --head --head-branch agent/x --stack rust --test-paths 'tests/**'` with the stub. Expect exit 0, R1 pass, summary `pass <head> (0 fail, 0 confirm; ran: R1 R4; skipped: R2 R3)`.
  3. Second branch from base where `fresh` passes on the base's code too. Expect exit 1, R1 entry naming `fresh` as passing on the base's code, class agent-fixable.
  4. Same second branch without the stub and `--test-cmd ek-no-such-toolchain test`. Expect exit 0, R1 and R4 `n/a`, summary `... ; n/a: R1 R4)`, never `all pass`.
- expected: exit codes and summaries as above; the caller checkout is untouched (HEAD and status unchanged).
