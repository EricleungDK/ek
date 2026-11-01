# ek

Agent workflow kit for Claude Code: one plugin, same setup on every machine and in cloud sessions.

| Part | What |
|---|---|
| `skills/orchestrate-agent` | `/ek:orchestrate-agent`: divide, delegate, verify acceptance |
| `skills/failure-triage` | classify a red result (sandbox/env, stale, flaky, unowned, real bug) before editing code; mech-review JSON: classify from entries, rounds per id (`mech.md`) |
| `skills/taste-it` | `/ek:taste-it`: verify by using it. Black-box taster, `.ek/scenarios/` regression suite, fix/human verdicts |
| `scripts/scenarios.py` | scenario runner: `run [ID]`, `check`, `can-fail REF`, `tree-hash`; path shown in the SessionStart `[ek] Scenario runner:` line |
| `scripts/mech-review.py` | mechanical review engine: `r2`/`red`/`all --repo . --base main --head HEAD --stack rust --test-paths 'tests/**' --protected-paths '.github/**' [--head-branch B --agent-prefix agent/ --test-cmd 'cargo test'] [--format text]` → contract JSON, exit 0 pass / 1 fail / 2 usage. R2 test-diff guard (`r2`); R1 red-first and R4 determinism (`red`, runs tests through a worktree, `n/a` without toolchain); R3 `skipped`. `--help` for contract |
| `skills/finish` | end-of-work report: done (evidence per criterion) or blocked (Needs-you block); mech per-check status with head SHA, skipped = not run |
| [`docs/testing-standard.md`](docs/testing-standard.md) | testing standard: what a good test is, forbidden cheats, mech-review vs code review |
| `.github/workflows/mech-review.yml` | reusable `workflow_call` mech-review: `guard` runs R2 with no toolchain, `red-first` runs R1/R4 with the stack toolchain, `report` merges both into one `<!-- mech-review -->` PR comment and sets the check. Adopters pin a tag: [`docs/mech-review-ci.md`](docs/mech-review-ci.md) |
| `.github/workflows/mech-review-self.yml` | ek's own caller of the reusable workflow (local `uses: ./`), the demo path |
| `scripts/mech-comment.py` | comment poster for the report job: `--envelope r2=FILE --envelope red=FILE` merged into one result, renders the JSON (summary, table, JSON block), find-or-edit via GitHub API; exit 0 pass / 1 fail / 3 API error / 4 no result. `scripts/mech_review/comment.py` is the pure render, `merge.py` the job merge |
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

Skill evals (kit dev only; plugin users need none of this):

```
claude plugin eval . --scaffold --allow-tools Bash Edit Write
```

`taste-act-*` cases grant Bash, so the eval sandbox needs `bubblewrap` + `socat` and no symlinks inside `~/.docker`. Their Bash is read-only, so graders check the commands run, not a runner PASS.
