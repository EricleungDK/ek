# mech-review-doctor/workflow-forms: the inputs doctor reads from a workflow are the real ones

- story: As a user I paste the doctor's inputs into my caller and they work, whatever form the workflow used.
- covers: A1 reads the repo's existing workflows (apt installs, sysctl, toolchain pin) and reports the exact input to set
- steps:
  1. `sudo apt-get install -y libfoo ${{ matrix.pkg }}`: the input holds `libfoo` and no fragment of the expression.
  2. `sudo sysctl vm.max_map_count=262144` (no `-w`, same effect): the command is in `setup-command`.
  3. `rustup default 1.86.0` in a run step: `rust-toolchain` is `1.86.0`.
- expected: `doctor --no-trial` inputs as above.
