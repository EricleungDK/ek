# runner/timeout: hung scenario

- story: As a dev, a scenario that hangs is killed and reported, not blocking me forever.
- covers: #9 branch (child) scenario; runner timeout
- steps: reuse parent setup; scenario `hang` sleeps 30s; `EK_SCENARIO_TIMEOUT=1 run`.
- expected: returns within ~10s, `FAIL hang: timeout after 1s`, exit 1.
