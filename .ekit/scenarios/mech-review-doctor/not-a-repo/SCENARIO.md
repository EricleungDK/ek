# mech-review-doctor/not-a-repo: misuse, no usable git repo

- story: As a user I point doctor at the wrong place and get a usage-class exit, not a report and not a crash.
- covers: A4 exit 2 on a git error
- steps: `doctor --repo` on a plain dir, on a path that does not exist, and on a repo with no commits.
- expected: exit 2 each time, nothing on stdout, a `mech-review:` line on stderr, no traceback.
