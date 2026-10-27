# Testing standard

One bar for tests in every ek-adopting repo. Apps link this from their agent docs (`AGENTS.md` / `CLAUDE.md`) and add a short local doc with repo specifics ([per-app doc](#per-app-doc)). Don't fork these rules into the app.

Status: R2 in progress (#13). R1, R3, R4 planned (#12). Until a check runs, a reviewer applies its rule by hand. Never report a planned or in-progress check as run.

## Contents

1. [Good test](#1-good-test)
2. [Test mix](#2-test-mix)
3. [Forbidden cheats](#3-forbidden-cheats)
4. [Checks](#4-checks)
5. [Mech-review vs code review](#5-mech-review-vs-code-review)
6. [Contract](#6-contract)
7. [Per-app doc](#per-app-doc)
8. [Before PR](#before-pr)

## 1. Good test

| Rule | Means |
|---|---|
| Public interface | Call the public API, CLI or endpoint. Assert observable output. Never private helpers. |
| One behaviour | One behaviour per test. Several asserts on one result are fine. |
| Spec-like name | Says the behaviour: `rejects_empty_title`, not `test_3` or `test_helper`. |
| Deterministic | No wall clock, network, unseeded random, or order dependence. Same code, same result. |
| Fast | Unit tests run in milliseconds. A slow test is justified in a comment. |
| Mocks at boundaries | Mock network, clock, filesystem, process, paid APIs. Never your own modules. Prefer a fake (in-memory store) to a mock. |
| No logic | No `if`, loops or computed expectations. Table rows are data, fine. |
| Specific assert | Exact value or error variant. Not "truthy", "is_ok", "not None". |
| Proven red | Fails before the fix, for the ticket's reason. See [R1](#4-checks). |

Specific assert:

```rust
assert!(parse("1.2").is_ok());                       // bad: any Ok passes
assert_eq!(parse("1.2"), Ok(Version::new(1, 2, 0))); // good
```

```python
assert parse("1.2")                     # bad: any truthy value passes
assert parse("1.2") == Version(1, 2, 0) # good
```

```ts
expect(parse("1.2")).toBeTruthy();                        // bad
expect(parse("1.2")).toEqual({ major: 1, minor: 2, patch: 0 }); // good
```

Name:

```
test_1                        # bad
parses_version_1_2            # bad: says nothing about the rule
rejects_empty_version_string  # good
```

## 2. Test mix

Many unit, some integration, few e2e.

| Level | Covers | Share | Speed |
|---|---|---|---|
| Unit | One function or module, through its public interface | most | ms |
| Integration | Modules together, real filesystem or DB in a temp dir | some | seconds |
| E2E | Built binary or app, real entry point | few | slowest |

If a behaviour can be tested at unit level, test it there. Push e2e to the one path per feature that proves it is wired.

## 3. Forbidden cheats

`forbidden` is the shortcut text an entry carries. `caught by`: R1–R4 ([checks](#4-checks)) or code review.

| Cheat | Caught by | Forbidden | Do instead |
|---|---|---|---|
| Delete a failing test | R2 | removed test `<name>` | Fix the code. If behaviour was removed on purpose, list a guard exception with reason. |
| Skip or ignore a test: `#[ignore]`, `@pytest.mark.skip`, `@pytest.mark.xfail`, `it.skip`, `test.only` | R2 | new skip/ignore/xfail/only marker | Fix the test failure. Can't run here: note verification debt, don't skip in code. |
| Drop assertions | R2 | fewer asserts in changed test file `<file>` | Keep the assert. Add a stronger one if needed. |
| Change expected value to match output | R2 (`confirm`) | changed expected value in `<name>` | Check the spec or ticket. The spec sets the value; fix the code. Intended change: reviewer confirms the `confirm` entry; no guard exception needed. |
| Lint/type suppression without reason: `#[allow]`, `# noqa`, `# type: ignore`, `@ts-ignore` | R2 | suppression without reason | Fix the lint. If it must stay, same-line reason (`#[allow(x, reason = "…")]`, `# noqa: E501 — url literal`). |
| Edit a protected path: CI, gate scripts, agent docs | R2 (`fail`, `needs-human`) | edit to protected path `<path>` | Stop. A human decides. Never edit the gate to pass. Not downgradable by guard exception. |
| Test passes before the fix | R1 (planned) | no failing `test(red)` commit | Write the test first in a `test(red): …` commit. It must fail there for the ticket's reason. |
| Weak or missing assert: test still passes with the code broken | R3 (planned) | MISSED mutant `<desc>` in `<file>` | Add the assert that kills the mutant. |
| Flaky test: passes and fails on same code | R4 (planned) | flaky test `<name>` | Find the nondeterminism (time, order, shared state, sleep). Fix it. Never retry to green. |
| Test asserts internals, mocks own code, bad name, logic in test | code review | n/a | Test through public interface. Mock only boundaries. Rename to the behaviour. Remove the logic. |

### Guard exceptions

Legit removal: list it in the PR body:

```
**Guard exceptions**
- <entry id or test name>: <reason>
```

- Covers `fail` entries only. A matching entry drops to `confirm`.
- Reviewer confirms each one or sends it back.
- Protected-path entries are `fail` + `needs-human`. Guard exceptions do NOT downgrade them.
- Empty reason is not an exception.

## 4. Checks

| Check | Enforces | Status |
|---|---|---|
| R1 red-first | First `test(red): …` commit touches only test paths. Its new tests fail there (or build fails: `compile-red`). They pass at head. Agent branches only, when production files changed. | planned (#12) |
| R2 test-diff guard | Cheat rows above: removed tests, new skip/ignore/xfail/only, fewer asserts, changed expected values, unreasoned suppressions, protected paths. | in progress (#13) |
| R3 mutation on diff | Mutation runs on changed production code only. MISSED mutant = `fail`. Timeout and unviable ignored. Budgeted. Budget hit with no MISSED so far = `partial`: reports `R3 partial (tested/total)`, does not block. | planned (#12) |
| R4 determinism | Each new or changed test runs 5× at head. Any failure = `fail`, class `agent-fixable`. | planned (#12) |

Statuses (per check, in the envelope):

- `pass`: ran, no `fail` entries.
- `fail`: at least one `fail` entry. Blocks.
- `partial`: R3 budget hit with no MISSED so far. Reported `R3 partial (tested/total)`. Does not block.
- `n/a`: tool not installable (`n/a (env)`). Not a pass. Say so in the report.
- `skipped`: check does not apply, or not implemented yet. Reason in the note. R1 is skipped for docs-only PRs and non-agent branches.

Checks not built yet (R1, R3, R4 today): engine emits `skipped` with note `not implemented`. Report them as not run, never as passed.

## 5. Mech-review vs code review

Both are required for merge. Neither overrides the other.

| | Mech-review | Code review |
|---|---|---|
| Answers | Facts: did the rule break? | Judgment: is the test good? |
| Input | git base..head, config, test and mutation runs | diff, mech-review JSON, spec |
| Same input, same output | Yes | No |
| Covers | Rows R1–R4 | Test design, naming, mock placement, spec fit, guard exception legitimacy |

Order:

1. Mech-review runs first. Its JSON (`<!-- mech-review -->` PR comment) goes to the reviewer.
2. Reviewer does not re-derive facts. It reads `confirm` entries and guard exceptions and decides each.
3. Reviewer cannot waive a `fail` entry. Fix it or report it.
4. Mech green does not mean review passed. Review approve does not excuse a `fail`.

## 6. Contract

Entry fields (stable; add fields, never rename):

| Field | Values |
|---|---|
| `id` | `<check>-<8 hex of sha1(check + file + test-or-rule)>`. Same across rounds, survives line moves. |
| `check` | `R1`, `R2`, `R3`, `R4`, `CI` (`CI` reserved for CI-level failures outside R1–R4, e.g. mech-review's own infra error) |
| `class` | `agent-fixable`, `needs-human`, `env` |
| `severity` | `fail` (blocks), `confirm` (reviewer decides) |
| `file`, `line` | location |
| `problem` | what broke |
| `hint` | intended fix |
| `forbidden` | shortcut not allowed |

Envelope: head SHA, base SHA, ek version, per-check status (`pass|fail|partial|n/a|skipped`) with note, entries. All green renders `all pass <sha>`.

## Per-app doc

Each repo writes a short `docs/testing.md` (or section in `AGENTS.md`). Link the standard. Add repo specifics only. Copy and fill:

```markdown
# Testing: <app>

Standard: https://github.com/EricleungDK/ek/blob/<ek-tag>/docs/testing-standard.md
Rules there apply here. This file holds only repo specifics.
Link must match the ek tag pinned in the caller workflow.

- Stack: rust
- Agent branch prefix: agent/
- Mutation budget: <minutes>

- Unit tests: `src/**` `#[cfg(test)]` modules
- Integration tests: `tests/*.rs`
- E2E: `tests/e2e/`, run by `make e2e`
- Gate: `make check` (fmt, clippy, test). Run before push.
- Mock here: HTTP client (`src/net.rs` trait), clock (`src/time.rs` trait)
- Protected paths: `.github/`, `scripts/gate.sh`, `AGENTS.md`, `CLAUDE.md`
- Guard exceptions: PR body, **Guard exceptions** section
```

Stack examples for test paths: Python `tests/test_*.py`, TS `src/**/*.test.ts`.

## Before PR

- `test(red)` commit exists, fails for the ticket's reason, before the fix.
- No skip, ignore, only, or new suppression without reason.
- No assert removed or weakened without a guard exception.
- Expected values match the spec, not the output.
- Gate passes locally. Say which checks were not run.
