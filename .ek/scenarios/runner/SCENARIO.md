# runner: run, check, stale

- story: As a dev with .ek/scenarios in my repo, I run the ek runner and get PASS/FAIL per scenario plus a freshness check.
- covers: #9 at least one scenario per deliverable (runner); runner reports a fresh PASS; real install via cloud/install.sh
- steps:
  1. Create a git repo with scenario `hello` (documented, run.sh exits 0) and `bad` (documented, exits 1).
  2. Install the kit with cloud/install.sh.
  3. `scenarios.py run` -> FAIL bad, PASS hello, exit 1; `check` exit 1.
  4. Remove `bad`, `run` -> PASS, exit 0; `check` exit 0.
  5. Edit a file; `check` exits 1 "stale".
  6. `tree-hash` prints a hash that changes with the edit.
- expected: exit codes and PASS/FAIL lines as above; nothing written into the kit repo.
- children: filter, timeout, no-layout, undocumented
