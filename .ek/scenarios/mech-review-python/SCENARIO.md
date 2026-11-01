# mech-review python: a skip marker is a fail, a clean change passes with skipped checks named, mutmut MISSED fails, plan runs R3 for a python change

- story: As a Python repo owner I run `mech-review.py` with `--stack python` and trust it: a test I skip to go green fails, a clean change says what it did not run, a mutant the tests miss fails with its location, and a production change makes the mutants job run.
- covers: R2 skip marker on a python test (fail, exit 1); clean python change (pass, exit 0, skipped checks named); R3 MISSED through mutmut replayed from the real `missed` fixture (fail, exit 1, changed lines only); `plan` on a python production change (run true, 4 shards)
- steps:
  1. Repo on base with `tests/test_core.py` (`test_add`) and `src/calc/core.py`. Head 1 adds `@pytest.mark.skip` to `test_add`. Run `scripts/mech-review.py r2 --base --head --stack python --test-paths 'tests/**'`.
  2. Expect exit 1, one R2 entry: class agent-fixable, file tests/test_core.py, id R2-*, summary `fail <head1> (1 fail, 0 confirm; ran: R2; skipped: R1 R3 R4)`.
  3. From base, add a passing test and run again. Expect exit 0 and summary `pass <head2> (0 fail, 0 confirm; ran: R2; skipped: R1 R3 R4)`.
  4. Head 3 is the real `head/src/calc/core.py` fixture (add and is_positive changed). Run `mutants --stack python` with a mutmut stub (MECH_TEST_STUB) that replays `tests/fixtures/mutmut/missed`. Expect exit 1, three R3 entries on the changed lines (src/calc/core.py:2 and :6), no entry for `sub` (unchanged line), summary `fail <head3> (3 fail, 0 confirm; ran: R3; skipped: R1 R2 R4)`.
  5. Run `plan --stack python --shards 4` on head 3. Expect `{"run":true,"count":4,"shards":[0,1,2,3]}`.
- expected: exit codes and summaries as above; the caller checkout is untouched (HEAD and status unchanged); nothing written into the kit repo.
