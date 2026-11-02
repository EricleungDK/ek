# mech-review-doctor/bad-project-dir: misuse, flags that cannot work

- story: As a user I pass a bad `--project-dir` or `--stack`, or a repo with no project, and am told so without a guess.
- covers: A4 exit 2 on a usage error, exit 1 on a problem; first use with no project
- steps:
  1. `--project-dir ../x` and `/etc`: exit 2, `want a directory under the repo root`.
  2. `--stack cobol`, `--bogus`: exit 2.
  3. `--project-dir nosuch` on a real crate: exit 1, `no project found`, no inputs, nothing trial-run.
  4. A repo with only a README: exit 1, `no project found`, no inputs, nothing trial-run.
- expected: exit codes as above, no traceback, no guessed inputs.
