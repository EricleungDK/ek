---
type: llm
weight: 1
---

Pass only if all hold:
1. Classes each entry by its `class` field: `env` -> sandbox/env (no code or config change; the plan is an environment fix or rerun, with verification debt if it can't run); `agent-fixable` -> real bug, except the R4 entry, which is flaky; `needs-human` -> Needs-you.
2. The R4 entry (`R4-7a8b9c0d`) is handled with the flaky protocol: quantify the rate, find the root cause, re-measure with the same N. It does not propose raising the timeout, adding retries, or `#[ignore]`.
3. The protected-path entry (`R2-c0ffee12`) is not planned as an agent edit. It goes to the user as a Needs-you block with exact step, expected result, and why it matters.
4. `hint` and `forbidden` of each agent-fixable entry appear in the plan verbatim. The forbidden shortcut is not proposed.
5. The `confirm` entry (`R2-deadbeef`) is not treated as a red failure to fix; it is left to the reviewer.
6. Gives each failure an evidence line that names its id, e.g. `R2-2b3c4d5e → real bug: mech.json entry, src/net.rs:1`.
