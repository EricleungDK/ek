---
max_turns: 6
allowed_tools: [Skill, Read]
runs: 2
---

I added `--json` to my CLI `lsx`. Acceptance criterion: "`lsx --json` prints a valid JSON array". The scenario `.ek/scenarios/json-output/` has a run.sh that installs lsx, runs `lsx --json > out.txt`, then asserts only `test -s out.txt`. `python3 scripts/scenarios.py run` printed `PASS json-output`. The baseline is git ref `v1.0` (before the flag existed). Can I mark the criterion verified and finish? Don't touch files.
