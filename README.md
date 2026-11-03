# ekit

Agent workflow kit: skills, hooks and CI that make a coding agent prove its work before it says "done".

- **Classify before fixing**: a red test is triaged (env, stale, flaky, real bug) before any code edit.
- **Verify by using it**: a black-box taster runs the deliverable as a real user, backed by repeatable scenarios.
- **Evidence-based finish**: every "done" carries a fresh result per acceptance criterion, or a Needs-you block.
- **Mechanical review in CI**: test-diff guard, red-first, determinism and mutation checks on every PR.

Works in Claude Code, Codex, GitHub Copilot, and any agent that reads [Agent Skills](https://skills.sh).

## Install

Pick **one** route per agent; installing two gives you every skill twice.

<details open>
<summary><b>Claude Code</b> (skills + hooks)</summary>

```bash
claude plugin marketplace add EricleungDK/ekit
claude plugin install ekit@ekit --scope user
```

Update: `claude plugin update ekit@ekit`.

</details>

<details>
<summary><b>Claude Code on the web</b> (claude.ai/code)</summary>

Cloud sessions load no plugins. Add to the environment's setup script:

```bash
curl -fsSL https://raw.githubusercontent.com/EricleungDK/ekit/main/cloud/setup.sh | bash
```

Installs skills + hooks into each repo's `.claude/`, hidden from `git status`, and pulls the latest on each setup. No repo found yet, or want the kit committed: `bash ~/.ekit/cloud/install.sh <repo>`.

</details>

<details>
<summary><b>Codex</b></summary>

```bash
codex plugin marketplace add EricleungDK/ekit
codex plugin add ekit@ekit
```

Updates at startup when `version` in `plugin.json` changes.

</details>

<details>
<summary><b>GitHub Copilot</b> (CLI and VS Code)</summary>

```bash
copilot plugin marketplace add EricleungDK/ekit
copilot plugin install ekit@ekit
```

Auto-update, once, in `~/.copilot/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "ekit": { "source": { "source": "github", "repo": "EricleungDK/ekit" }, "autoUpdate": true }
  }
}
```

VS Code: **Chat: Install Plugin From Source** → `https://github.com/EricleungDK/ekit`.

</details>

<details>
<summary><b>Any other agent</b> (Cursor, Gemini CLI, OpenCode, Windsurf, Amp, …)</summary>

```bash
npx skills@latest add EricleungDK/ekit -a <agent>   # omit -a to choose
```

Copies editable skill files. Update: `npx skills@latest update`.

</details>

### Hooks and scripts outside Claude Code

The hooks (preflight, failure hints, finish gate) run in Claude Code. Elsewhere, skills still work: those that need the kit's scripts use `~/.ekit`, cloned once:

```bash
git clone --depth 1 https://github.com/EricleungDK/ekit ~/.ekit
```

`orchestrate-agent` relies on Claude Code subagents (`Agent`, `SendMessage`); the other skills are harness-neutral.

## Skills

| Skill | Use |
|---|---|
| [`failure-triage`](skills/failure-triage/SKILL.md) | A test, build or CI job goes red: classify it (sandbox/env, stale, flaky, unowned, real bug) before editing code. Reads mech-review JSON directly. |
| [`taste-it`](skills/taste-it/SKILL.md) | Verify a deliverable by using it: black-box taster, `.ekit/scenarios/` regression suite, fix/human verdicts. |
| [`finish`](skills/finish/SKILL.md) | End-of-work report: done (evidence per criterion) or blocked (Needs-you block). |
| [`ci-doctor`](skills/ci-doctor/SKILL.md) | Set up or repair a repo's mech-review CI; ends in a PR a person merges. |
| [`orchestrate-agent`](skills/orchestrate-agent/SKILL.md) | `/ekit:orchestrate-agent`: divide a task, delegate to subagents, verify acceptance. User-invoked only. |

## Hooks (Claude Code)

| Hook | Does |
|---|---|
| `SessionStart` | Preflight warnings + working rules (failure-triage, blockers) into context; prints the scenario runner path. |
| `UserPromptSubmit` | Prompt starts with `/ekit:orchestrate-agent` → arms the finish gate for the session. |
| `PostToolUseFailure` | Known Bash failure signatures → one context line. |
| `Stop` / `SubagentStop` | Orchestrate sessions only: blocks once per new change set until the finish report is given; in repos with `.ekit/scenarios/`, until a fresh scenario PASS (taste-it). |

## mech-review CI

Reusable GitHub workflow that checks agent PRs mechanically and posts one `<!-- mech-review -->` comment:

| Check | Rule |
|---|---|
| `guard` | R2: tests not weakened or deleted (no toolchain needed). |
| `red-first` | R1: new tests fail before the fix. R4: results are deterministic. |
| `mutants` | R3: mutation testing on the diff (cargo-mutants, mutmut, Stryker). Runs only when production code changed. |

Stacks: Rust, Python, TypeScript. Adopt with `/ekit:ci-doctor`, or by hand: [docs/mech-review-ci.md](docs/mech-review-ci.md). Testing rules behind the checks: [docs/testing-standard.md](docs/testing-standard.md).

<details>
<summary>Scripts</summary>

| Script | Does |
|---|---|
| `scripts/mech-review.py` | Review engine: `r2`, `red`, `mutants`, `all`, `plan`, `merge`, `doctor`. Contract JSON; exit 0 pass / 1 fail / 2 usage. `--help` for flags. |
| `scripts/scenarios.py` | Scenario runner: `run [ID]`, `check`, `can-fail REF`, `tree-hash`. |
| `scripts/mech-comment.py` | Merges job envelopes, renders and posts the PR comment. Exit 0 pass / 1 fail / 3 API error / 4 no result. |

</details>

## Development

```bash
bash tests/run.sh
```

Skill evals (kit dev only):

```bash
claude plugin eval . --judge-model claude-opus-5-5 --scaffold --allow-tools Bash Edit Write
```

`taste-act-*` cases grant Bash, so the eval sandbox needs `bubblewrap` + `socat` and no symlinks inside `~/.docker`. Their Bash is read-only, so graders check the commands run, not a runner PASS.
