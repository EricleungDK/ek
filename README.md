# ek

Agent workflow kit for Claude Code: one plugin, same setup on every machine and in cloud sessions.

| Part | What |
|---|---|
| `skills/orchestrate-agent` | `/ek:orchestrate-agent`: divide, delegate, verify acceptance |
| `skills/failure-triage` | classify a red result (sandbox/env, stale, flaky, unowned, real bug) before editing code |
| `skills/taste-it` | `/ek:taste-it`: verify by using it. Black-box taster, `.ek/scenarios/` regression suite, fix/human verdicts |
| `scripts/scenarios.py` | scenario runner: `run [ID]`, `check`, `can-fail REF`, `tree-hash`; path shown in the SessionStart `[ek] Scenario runner:` line |
| `skills/finish` | end-of-work report: done (evidence per criterion) or blocked (Needs-you block) |
| `SessionStart` hook | preflight warnings + working rules into context |
| `PostToolUseFailure` hook | known Bash failure signatures → one context line |
| `Stop` / `SubagentStop` hook | blocks once per new change set until the finish report is given |

## Install

Local (each PC/laptop):

```
claude plugin marketplace add EricleungDK/ek
claude plugin install ek@ek --scope user
```

Cloud (claude.ai/code): cloud sessions load no plugins, so add to the environment's setup script:

```
curl -fsSL https://raw.githubusercontent.com/EricleungDK/ek/main/cloud/setup.sh | bash
```

It installs skills + hooks into each repo's `.claude/`, hidden from `git status`. If no repo is found at setup time, or to commit the kit into a repo instead: `bash ~/.ek/cloud/install.sh <repo>`.

Update: `claude plugin update ek@ek` locally; cloud pulls on each setup.

## Test

```
bash tests/run.sh
```
