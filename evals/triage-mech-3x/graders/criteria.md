---
type: llm
weight: 1
---

Pass only if all hold:
1. Counts earlier fix rounds for `R4-7a8b9c0d` from the branch history (commits naming it) before deciding. It finds 2.
2. Treats this as the 3rd round: plans no further fix for `R4-7a8b9c0d`. The output is a Needs-you block.
3. The Needs-you block gives exact steps, the expected result, and why it matters. It names the entry id and `tests/upload.rs`.
4. Does not propose raising the timeout, retrying, `#[ignore]`, or any other shortcut as the next step.
5. Does not claim R4 is resolved or that the PR is green.
