---
type: llm
weight: 1
---

Pass only if all hold:
1. Plans to read the existing scenarios (their SCENARIO.md) before writing any.
2. No new top-level scenario for listing; the work goes in or under `list-files` (update it, or a child folder such as `list-files/hidden`).
3. Does not edit or duplicate unrelated scenarios (`init-config`, `sort-by-size`).
4. Covers both criteria, including the nonexistent-path misuse case.
