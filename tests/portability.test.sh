#!/bin/bash
# Other harnesses (Codex, Copilot, skills.sh) read .claude-plugin/plugin.json and copy skills without hooks or scripts.
source "$(dirname "$0")/lib.sh"

listed="$(python3 -I -c 'import json,sys; print("\n".join(sorted(json.load(open(sys.argv[1]))["skills"])))' "$ROOT/.claude-plugin/plugin.json" 2>&1)"
dirs="$(cd "$ROOT" && for d in skills/*/; do echo "./${d%/}"; done | sort)"
eq "$listed" "$dirs" "plugin.json skills array = skills/*/"

repo="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("repository",""))' "$ROOT/.claude-plugin/plugin.json")"
eq "$repo" "https://github.com/EricleungDK/ekit" "plugin.json repository"

# A skill that needs kit scripts must work with no SessionStart hook (no `[ekit] Scenario runner:` line).
for f in $(grep -l '<kit>' "$ROOT"/skills/*/SKILL.md); do
  has "$(cat "$f")" '~/.ekit' "$(basename "$(dirname "$f")"): <kit> falls back to ~/.ekit"
done

readme="$(cat "$ROOT/README.md")"
has "$readme" "claude plugin install ekit@ekit" "README: Claude Code install"
has "$readme" "codex plugin marketplace add EricleungDK/ekit" "README: Codex install"
has "$readme" "copilot plugin marketplace add EricleungDK/ekit" "README: Copilot install"
has "$readme" "npx skills@latest add EricleungDK/ekit" "README: other agents install"
done_tests
