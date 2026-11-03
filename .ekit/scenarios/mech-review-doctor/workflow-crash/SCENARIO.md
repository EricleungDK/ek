# mech-review-doctor/workflow-crash: ordinary shell in a workflow never crashes the doctor

- story: As a user whose CI wraps a long `apt-get install` with `\`, or echoes the command in quotes, doctor reads the workflow and reports; it does not die on it.
- covers: A1 reads the repo's existing workflows (apt installs); A2 not a crash; A4 a traceback's exit 1 must not pass for "problems"
- steps:
  1. A `run: |` with `sudo apt-get install -y \` and the packages on the next lines. `doctor --no-trial`.
  2. A step `run: echo "sudo apt-get install -y curl"`. `doctor --no-trial`.
- expected: JSON on stdout, no traceback; in 1 `extra-apt-packages` is `libfoo-dev libbar-dev`.
