# mech-review-doctor/trial-failure: a toolchain or sandbox failure is an entry, not a crash

- story: As a user on a machine without the toolchain, or where the trial cannot start, doctor still reports, names the failure and leaves no worktree.
- covers: A2 a sandbox or toolchain failure is a reported entry, not a crash; A3 no leftover worktree; A4 exit 1
- steps:
  1. Good caller, no toolchain (MECH_TEST_STUB is a path that does not exist): expect exit 1, tests `env`, an env entry `` `cargo` not found ``.
  2. A throwaway worktree that cannot be made (a `post-checkout` hook that exits 7): expect exit 1, tests `unavailable`, an env entry `trial could not run`, and the static read still in `inputs`.
- expected: JSON on stdout, no traceback, one worktree, git state unchanged.
