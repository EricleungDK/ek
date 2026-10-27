# Mech-review entries

Entries arrive classified. Use `class`, `severity`, `hint`, `forbidden`. Don't re-derive from logs.

## Gate

1. Envelope `head` ≠ `git rev-parse HEAD` → **stale** ([stale.md](stale.md): judge only the run for your SHA). Rerun mech-review at HEAD.
2. `severity: confirm` → not red. Reviewer decides. List under Open (finish).
3. `severity: fail` → classify below.

## Class map

| `class` | Label (use verbatim) | Next action |
|---|---|---|
| `env` | sandbox/env | No app code or test change. Fix the environment (install the missing tool, or rerun where it failed). Protected CI config → Needs-you. Can't rerun → verification debt. |
| `agent-fixable`, check `R4` | flaky | Follow [flaky.md](flaky.md). |
| `agent-fixable`, other | real bug | Fix red→green: the entry's test or rule. |
| `needs-human` | Needs-you | No edit. Needs-you block (finish shape; `Decide:` in place of `Run:`). |

Each `agent-fixable` fail: open its fix plan with two lines, verbatim: `Fix: <hint>` and `Forbidden: <forbidden>`. Your steps go after them. Never take the forbidden route.

## Rounds

Fix rounds per id = commits on this branch whose body names it:

`git log --fixed-strings --grep="mech: <id>" --format=%h <base>..HEAD | wc -l`

`<base>` = the envelope's `base` SHA. No envelope base → merge-base of the PR base branch and HEAD.

Each fix commit for an id carries the body line `mech: <id>`.

- Count ≥ 2 and the id still fails → **3rd round**: no fix. Needs-you block: `Blocker: <id> unresolved after 2 fix rounds`, with the entry, its file, and the decision needed.
- Else → fix; commit with `mech: <id>` in the body.

## Evidence

Open the answer with one line per fail entry, label from the class map verbatim: `<id> → <label>: entry <file>:<line>, <problem>`.
