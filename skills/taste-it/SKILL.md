---
name: taste-it
description: Verify a deliverable by using it as a real user, via black-box scenarios in .ek/scenarios/. Use when acceptance criteria need a user run, when adding or changing scenarios, when a scenario fails, or before calling a feature done in a repo with .ek/scenarios/. Not /code-review (that reads code; this uses the result).
---

Tests green is not "works". A **taster** (a subagent, never the implementer) acts as a real user; the project's **scenarios** keep that user run repeatable. Separate gate from /code-review: review asks "is the code right", taste asks "does it work in use".

## 1. Brief the taster

Black box. The brief holds only:
- acceptance criteria
- install and launch steps, as a user gets them

No source, diff, or implementer reasoning in the brief. Taster rules:
- **Real install** from the repo, as the user will (see [drivers.md](drivers.md)); never the source tree.
- **Fresh temp dir** for every run.
- **Act as a user**: ordinary tools only.
- **Break it**: misuse, bad input, first-time use with no config.

Taster writes or updates scenarios and reports each finding with the scenario id.

## 2. Scenarios

Runner: use the `[ek] Scenario runner:` line from session context (absolute path, same in plugin and cloud installs). Absent: `python3 <kit>/scripts/scenarios.py`. Below, `RUN` = that command.

Layout, committed in the repo:

```
.ek/scenarios/<use-case>/SCENARIO.md
                        /run.sh        # real install + drive + assert; exit 0 = pass
                        /fixtures/
.ek/scenarios/<use-case>/<child>/...   # branch
```

`SCENARIO.md` fields:
- **story**: user story, one line
- **covers**: acceptance criteria ids/text
- **steps**: what the user does
- **expected**: observable result

No `SCENARIO.md` → FAIL. `run.sh` gets `EK_REPO`, `EK_SCENARIO_DIR`, `EK_PARENT_DIR` in a fresh temp cwd; a child reuses its parent's setup and fixtures via `EK_PARENT_DIR`. Scenarios write to their temp cwd only; writing into `EK_REPO` fails the run.

### Reuse before write

Read every existing `SCENARIO.md` first. Then, in order:
1. Existing scenario already covers the use case → reuse; add the new criterion to **covers**, extend **steps**.
2. Behaviour changed → update that scenario.
3. Feature built on a use case → **branch**: child folder under it.
4. Only a new use case → new top-level scenario.

Name the scenarios read and the files created or edited before writing any.

## 3. Run

| Command | Use |
|---|---|
| `RUN run` | all scenarios |
| `RUN run <id>` | one scenario + its children (fix loop) |
| `RUN check` | exit 0 iff fresh PASS for the current tree; a filtered `run <id>` leaves it "partial run" → finish with a full `RUN run` |
| `RUN can-fail <baseline-ref>` | `CAN-FAIL ✓ <id>` or `CANNOT FAIL <id>`: passes at baseline |
| `RUN tree-hash` | current tree hash |

Evidence is the runner's `PASS`/`FAIL` lines and results.json, never the taster's say-so. Any edit makes the PASS stale; the Stop gate wants a **fresh PASS**. Missing driver tool (preflight warns) → scenario unrunnable: verification debt (finish skill), not skipped.

## 4. Quality bar

Done when all hold:
- every acceptance criterion is in the **covers** of ≥1 scenario
- ≥1 misuse or failure scenario for the change
- every scenario whose **covers** include this change's criteria is `CAN-FAIL ✓` at the baseline; one that `CANNOT FAIL` proves nothing → rewrite its assertion, rerun `can-fail`. A `CANNOT FAIL` scenario covering only pre-existing behaviour is expected (regression guard).
- `RUN run` exit 0, then `RUN check` exit 0

## 5. Verdicts

Each finding gets one verdict.

**fix**: the agent can repair it. Send back to the implementer with the failing scenario id and its transcript as the repro, then re-run the **full** set. Max 3 rounds; still red → **human** with the 3 transcripts.

**human**: only when nothing the agent can reach, CI included, can run the check, or it needs human judgement (taste, visual, real account). Reaching for human on a runnable check is a mistake: reclass as fix and run it. Each human item is a Needs-you block (finish skill) with exact steps, expected result, why it matters; the criterion row is 👤 human-only.
