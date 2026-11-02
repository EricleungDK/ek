# mech-review-doctor/interrupted: a stopped trial leaves no worktree

- story: As a user (or a `timeout` wrapper) I stop a slow doctor run and my repo holds no stale worktree registration.
- covers: A3 no leftover worktree
- steps: Tests that hang at HEAD. Start `doctor`, wait until the tests run, send SIGTERM (Ctrl-C's SIGINT too).
- expected: after either signal `git worktree list` shows the repo alone and the temp dir is empty.
