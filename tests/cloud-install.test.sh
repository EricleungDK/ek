source "$(dirname "$0")/lib.sh"
IN="$ROOT/cloud/install.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
R="$T/repo"; mkdir -p "$R/.claude"; git -C "$R" init -q
echo '{"permissions":{"allow":["Bash(ls)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}' > "$R/.claude/settings.json"
git -C "$R" add .; git -C "$R" -c user.email=t@t -c user.name=t commit -qm init

bash "$IN" "$R" >/dev/null
S="$R/.claude/settings.json"
for s in failure-triage finish orchestrate-agent taste-it; do
  [[ -f $R/.claude/skills/$s/SKILL.md ]] && ok "skill $s copied" || fail "skill $s copied"
done
[[ -f $R/.claude/skills/failure-triage/flaky.md ]] && ok "sibling files copied" || fail "sibling files copied"
eq "$(jq -r '.permissions.allow[0]' "$S")" "Bash(ls)" "existing settings kept"
has "$(jq -c '.hooks.Stop' "$S")" "echo mine" "existing hook kept"
has "$(jq -c '.hooks.Stop' "$S")" "$ROOT/scripts/finish-gate.py" "kit Stop hook added, absolute path"
has "$(jq -c '.hooks.SessionStart' "$S")" "session-start.py" "SessionStart added"
has "$(jq -c '.hooks.PostToolUseFailure' "$S")" "failure-match.py" "PostToolUseFailure added"
has "$(jq -c '.hooks.SubagentStop' "$S")" "finish-gate.py" "SubagentStop added"
[[ -f $R/.claude/skills/taste-it/drivers.md ]] && ok "taste-it sibling copied" || fail "taste-it sibling copied"
lacks "$(cat "$S")" "CLAUDE_PLUGIN_ROOT" "no unresolved plugin var"

bash "$IN" "$R" >/dev/null
eq "$(jq '.hooks.Stop | length' "$S")" "2" "idempotent: no duplicate hooks"

eq "$(git -C "$R" status --porcelain)" "" "kit files hidden from git status"

# repo without .claude/
R2="$T/repo2"; mkdir -p "$R2"; git -C "$R2" init -q
bash "$IN" "$R2" >/dev/null
has "$(jq -c .hooks.Stop "$R2/.claude/settings.json")" "finish-gate.py" "creates settings when absent"
eq "$(git -C "$R2" status --porcelain)" "" "new settings hidden from git status"

# existing repo skill with same name is not overwritten
R3="$T/repo3"; mkdir -p "$R3/.claude/skills/finish"; echo mine > "$R3/.claude/skills/finish/SKILL.md"; git -C "$R3" init -q
bash "$IN" "$R3" >/dev/null
eq "$(cat "$R3/.claude/skills/finish/SKILL.md")" "mine" "repo's own skill wins"

done_tests
