# runner/no-layout: misuse, repo without scenarios

- story: As a first-time user I run the runner in a repo that has no .ek/scenarios and get told what to create.
- covers: #9 misuse scenario; runner no-scenarios handling
- steps: install kit into a plain git repo; `run`, `check`, `run x`.
- expected: exit 2 with the layout `.ek/scenarios/<slug>/SCENARIO.md + run.sh`; no crash/traceback.
