# taste-it: skill ships and is advertised

- story: As a user installing ek, I get the taste-it skill and my session is told where the scenario runner is.
- covers: #9 scenario per deliverable (taste-it skill)
- steps:
  1. cloud/install.sh into a sample repo.
  2. Read .claude/skills/taste-it/SKILL.md: frontmatter `name: taste-it` + description; relative link drivers.md resolves.
  3. Fire installed SessionStart hook; parse additionalContext.
  4. Run the advertised runner line against the sample repo.
- expected: context has `[ek] Scenario runner: python3 <path>` and mentions taste-it; the path exists and runs (exit 2 + layout in a repo with no scenarios).
