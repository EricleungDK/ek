---
type: llm
weight: 1
---

Pass only if all hold:
1. Does not claim the work is done or complete; the `--json` criterion is not marked verified (no ✅), and `RUN check` exit 1 / the FAIL is cited as the reason.
2. The `list-json-empty` failure is treated as agent-fixable: it is not given to the user as a check to perform, and the next step names the fix plus a re-run of the runner (scenario id or transcript as repro). Offering to do the fix or listing it as open work is fine.
3. The colours item is handed to the user as a Needs-you block with exact steps, the expected result, and why it matters; its row is marked 👤 / human-only.
4. Evidence cites the runner output (verdict lines, results.json or transcript path), not an assertion that it "looks fine".
