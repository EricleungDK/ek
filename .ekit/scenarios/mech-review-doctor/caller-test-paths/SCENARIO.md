# mech-review-doctor/caller-test-paths: a caller whose test-paths miss the tests is a problem

- story: As a user with a crate in `crates/app` and a caller left on `tests/**`, doctor tells me R2 is looking in the wrong place.
- covers: A1 each problem named with the exact caller input to set; A4 exit 1
- steps: Crate in `crates/app`, caller with every input right except `test-paths: tests/**`, which matches no file. `doctor`.
- expected: exit 1, one entry with hint `set test-paths: crates/app/tests/**`.
