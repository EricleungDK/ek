---
name: finish
description: End-of-work report, done or blocked. Use before saying work is done, before a subagent reports back, and when stopping on a blocker that needs the user.
---

Every outcome ends in one report, with **evidence** per claim. "Done" is a claim the report proves.

Trivial work (no acceptance criteria, no code behaviour changed) gets the light form instead: one line per change with its evidence, plus what stays uncommitted. Steps below apply to everything else.

## 1. Re-verify

At report time, rerun the decisive commands: tests, typecheck, build. Counts and results come from this run, never from memory.

- CLI or app deliverable: run the real install and launch the way the user will (`pip install -e .` / `cargo install --path .` / `npm i -g .`, then the command). A built binary or `playwright --list` counts as not run.
- State the env each command ran in: sandboxed or unsandboxed.

- Mech-review envelope (PR comment or CLI): per check, `<check> <status> <head sha>` copied from it. `skipped`/`n/a` = not run: a ⚠️ row, with its note as debt. Quote `summary` only when no check is skipped; never write "all pass" yourself. Envelope `head` ≠ HEAD → stale: rerun mech-review at HEAD first.
- Repo with `.ek/scenarios/` (taste-it skill): a scenario-backed criterion is verified by the runner, never the taster's say-so. Run `RUN run`, then `RUN check`. Evidence: the `PASS`/`FAIL` line, the results.json or transcript path, tree hash fresh (`check` exit 0). Any `FAIL`, stale or partial `check` (exit 1) = not done: no ✅ row, no plain "done"; a fix-class FAIL stays an agent job (fix, full `RUN run`, `RUN check`), listed under Open, never handed to the user as a question or check.

Done when: every criterion has a fresh result or a reason it can't run here.

## 2. Close the loop

- GitHub issue in scope: comment with the evidence; close it if the work completes it (`gh issue close <N> --comment ...`), else update it.
- Remove worktrees and branches you created that are merged or abandoned.
- Uncommitted files: commit them if the flow commits, else list them as intentionally uncommitted.

## 3. Report

Pick the branch.

### Done

```
## Finish: done
| Criterion | Status | Evidence |
|---|---|---|
| <criterion> | ✅ verified | `<cmd>` → exit 0, <key output> |
| <criterion> | ⚠️ not verified | <why>; run: `<exact cmd>` |
| <criterion> | 👤 human-only | <what the user checks>; Needs-you block below |
Mech <head sha>: R1 <status> · R2 <status> · R3 <status> · R4 <status>
TDD: <test> red (`<failure line>`) → green (`<cmd>` exit 0)
Env: <sandboxed|unsandboxed>
Verification debt: <items, or none>
Open: <issues, flakes, follow-ups, confirm entries for reviewer, or none>
```

Scenario row evidence: `RUN run <id>` → `PASS <id>`, `<results.json / transcript path>`, `RUN check` exit 0.

Each 👤 row gets a Needs-you block (same shape as in Blocked; Run/Expect become the exact steps and expected result, Why = what the check protects). Verdict stays "done except the rows marked ⚠️/👤".

Each unresolved `needs-human` mech entry gets one too, with `Decide:` in place of `Run:`. Such an entry means not done.

Any ⚠️ row means the report says "done except the rows marked ⚠️", never plain "done".

### Blocked

The same blocker 3×, a mech id at its 3rd fix round (failure-triage, mech.md rounds), a denied command, a missing credential or quota: stop retrying, and mark the goal **blocked**, not complete.

```
## Finish: blocked
Blocker: <what failed, 3× evidence, or mech id + its fix rounds>
Needs you:
  Run: ! <exact command>
  Expect: <output that means it worked>
  Then: <reply "done" / paste the output here>
  Why: <what it unblocks>
Done so far: <criteria table, as above>
Verification debt: <blocked cmd → reason → where to rerun>
```

A denied command keeps its exact form in the Needs-you block; the user decides. A command that prompts for a password (`sudo`, interactive logins) goes under "Run in your own terminal:" instead of `!`. The blocked report's verdict is "blocked" throughout; the done branch's "done except" wording stays out of it.

## Verification debt

Every check you could not run: `<cmd> → <reason> → <where to rerun: unsandboxed / CI / user machine>`. Gather it during the work (failure-triage feeds it); it all lands here.
