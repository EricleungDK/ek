---
type: llm
weight: 1
---

Pass only if all hold:
1. The new scenario(s) sit in or under the existing `list-files` scenario (edit it, or a child folder such as `list-files/hidden`), not a new top-level folder, and `init-config` / `sort-by-size` are untouched.
2. Both criteria are covered, including the `/nonexistent` misuse case asserting a non-zero exit.
3. Each new or edited SCENARIO.md has story, covers, steps, expected.
4. The agent ran (or tried to run) the scenario runner and reports its actual output; if the environment blocks it (e.g. read-only filesystem), it says the scenarios are not verified yet instead of claiming they pass.
