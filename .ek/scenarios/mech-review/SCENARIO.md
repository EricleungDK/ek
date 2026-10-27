# mech-review: R2 catches a removed test, clean change is all pass

- story: As a repo owner I run mech-review on base...head locally and get the contract JSON plus an exit code I can trust.
- covers: mech-review CLI; R2 removed test fn (fail, exit 1); clean change renders `all pass <sha>` (exit 0)
- steps:
  1. Repo with `tests/math.rs` holding tests `adds` and `keeps` on base.
  2. Head deletes `keeps` (cheat to go green). Run `scripts/mech-review.py r2 --base --head --stack rust --test-paths 'tests/**'`.
  3. Expect exit 1, JSON with one R2 entry: class agent-fixable, file tests/math.rs, id R2-*.
  4. From base, add a new test and run again. Expect exit 0 and summary `all pass <head sha>`.
- expected: exit codes and JSON fields as above; nothing written into the kit repo.
