# mech-review doctor: finds the stack and project dir, reads the workflows, trial-runs at HEAD, names each fix, writes nothing

- story: As a repo owner adopting mech-review I run `mech-review.py doctor` with no hints and get what my caller workflow needs, a verdict on the tests and the mutation tool at HEAD, and one exact input for each problem, with my repo left as it was.
- covers: A1 no hints: detects stack (rust, python, ts) and project dir, reads the workflows (apt, sysctl, toolchain pin), each problem names the exact caller input; A2 trial-runs tests and the mutation tool at HEAD and reports verdicts; A3 deterministic, writes nothing (`git status` clean, no leftover worktree); A4 exit 0 no problems, 1 problems
- steps:
  1. Clone the kit into the temp dir (the install). Everything runs `python3 -I <clone>/scripts/mech-review.py doctor`; a stub (MECH_TEST_STUB) stands in for the toolchain.
  2. Rust crate in `crates/app`, a CI workflow with apt, sysctl and a toolchain pin, no caller. `doctor --no-trial`: expect exit 1, detected rust and `crates/app`, the six exact inputs, one needs-human entry that repeats them, and the stub never run.
  3. Add a caller with those inputs. `doctor`: expect exit 0, summary `ok <head>`, tests pass, tool present, no entries, tests run in `crates/app` of a throwaway worktree.
  4. Caller with a wrong `project-dir` and `rust-toolchain`: expect exit 1 and hints `set project-dir: crates/app`, `set rust-toolchain: 1.96.0`.
  5. Tests fail at HEAD: expect exit 1, tests `fail`, an entry naming the command.
  6. Python at the root, ts in `web`: expect the stack, project dir and test-paths detected with no hints.
  7. Two crates: expect exit 1, `several projects` naming both, no inputs. `--project-dir` settles it.
  8. Run twice on a repo with uncommitted changes and an untracked file: expect identical bytes, a trial at HEAD, and git state unchanged.
- expected: exit codes and JSON as above; no leftover worktree or temp dir.
- children: not-a-repo, bad-project-dir, trial-failure, workflow-crash, workflow-forms, caller-test-paths, broken-mutation-tool, interrupted
