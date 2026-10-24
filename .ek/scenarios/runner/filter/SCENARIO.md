# runner/filter: run one id

- story: As a dev in a fix loop I run one scenario (and its children) and a partial run never counts as fresh.
- covers: #9 branch (child) scenario; runner filter
- steps: reuse parent fixture; repo has `a`, `a/kid`, `b` (b fails). `run a` -> only a and a/kid ran; `run nope` -> exit 2; `check` after `run a` -> exit 1 "partial".
- expected: b not run, so exit 0 for `run a`; unknown id exit 2; check not green until full run.
