---
type: llm
weight: 1
---

Pass only if all hold:
1. B is reclassed as fix (or simply run as a scenario): the agent can run it itself, so human is not allowed.
2. A is fix: sent back to the implementer with the failing scenario as the repro, followed by a full re-run of all scenarios, max 3 rounds.
3. C is human, delivered as a Needs-you block with exact steps, expected result and why it matters.
4. Does not accept the taster's human label for B.
