---
max_turns: 8
allowed_tools: [Skill, Read]
runs: 2
---

Repo `lsx` (a CLI) has a `.ek/scenarios/` folder from earlier features; you have not looked inside it yet. Existing scenario ids: `list-files`, `list-files/sort-by-size`, `init-config`. `list-files` covers "lsx prints entries of a dir".

New work: add `--hidden` to show dotfiles when listing. Criteria: "`lsx --hidden` shows dotfiles"; "`lsx --hidden /nonexistent` exits non-zero with an error". Tell me your plan for the scenarios before doing anything else. Don't touch files.
