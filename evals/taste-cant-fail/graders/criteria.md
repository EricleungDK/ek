---
type: llm
weight: 1
---

Pass only if all hold:
1. Does not mark the criterion verified or finish on this PASS.
2. Identifies that the scenario can't fail: the assertion (non-empty output) would also pass on the previous release's plain-text output, so the PASS proves nothing.
3. Plans to strengthen the assertion to check a valid JSON array and to run can-fail against the baseline (v1.0), expecting it to fail there.
4. Does not hand the criterion to the user as a human item.
