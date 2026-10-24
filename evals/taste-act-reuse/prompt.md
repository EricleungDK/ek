---
max_turns: 25
allowed_tools: [Skill, Read, Bash, Edit, Write, Glob, Grep]
runs: 2
---

I just implemented `--hidden` in my CLI `lsx.py` (shows dotfiles when listing). Criteria: "`lsx --hidden` shows dotfiles" and "`lsx --hidden /nonexistent` exits non-zero with an error". Add the scenarios that verify this to the repo and run them.
