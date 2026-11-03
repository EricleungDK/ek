#!/bin/bash
# Other harnesses (Codex, Copilot, skills.sh) read .claude-plugin/plugin.json and copy skills without hooks or scripts.
source "$(dirname "$0")/lib.sh"

listed="$(python3 -I -c 'import json,sys; print("\n".join(sorted(json.load(open(sys.argv[1]))["skills"])))' "$ROOT/.claude-plugin/plugin.json" 2>&1)"
dirs="$(cd "$ROOT" && for d in skills/*/; do echo "./${d%/}"; done | sort)"
eq "$listed" "$dirs" "plugin.json skills array = skills/*/"

repo="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("repository",""))' "$ROOT/.claude-plugin/plugin.json")"
eq "$repo" "https://github.com/EricleungDK/ek" "plugin.json repository"

# A skill that needs kit scripts must work with no SessionStart hook (no `[ek] Scenario runner:` line).
for f in $(grep -l '<kit>' "$ROOT"/skills/*/SKILL.md); do
  has "$(cat "$f")" '~/.ek' "$(basename "$(dirname "$f")"): <kit> falls back to ~/.ek"
done

readme="$(cat "$ROOT/README.md")"
has "$readme" "claude plugin install ek@ek" "README: Claude Code install"
has "$readme" "codex plugin marketplace add EricleungDK/ek" "README: Codex install"
has "$readme" "copilot plugin marketplace add EricleungDK/ek" "README: Copilot install"
has "$readme" "npx skills@latest add EricleungDK/ek" "README: other agents install"
done_tests
