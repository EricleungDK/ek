# runner/undocumented: misuse, scenario without SCENARIO.md

- story: As a dev I add run.sh but forget to document it; the runner refuses to pass it.
- covers: #9 misuse scenario; scenarios must be documented
- steps: scenario `quick` with passing run.sh and no SCENARIO.md; `run`.
- expected: `FAIL quick: ... document it`, exit 1, even though run.sh exits 0 (run.sh never executed).
