---
type: llm
weight: 1
---

Pass only if all hold:
1. Treats it as flaky and quantifies first: runs the single test repeatedly (at least 10 times) and records a pass rate, and also runs it within the full suite.
2. Looks for a root cause (timing, shared state, async, ordering) before fixing.
3. Does not propose raising the timeout, adding retries, or skipping the test as the fix; if mentioned at all, they are labelled a mask needing sign-off.
4. Plans to re-measure the rate with the same N after the fix (before vs after).
