#!/bin/bash
source "$EK_REPO/.ek/scenarios/lib.sh"
mk_repo; install_kit
f="$SAMPLE/.claude/skills/taste-it/SKILL.md"
[[ -f $f ]] || fail "taste-it skill not installed"
eq fm-open "$(sed -n 1p "$f")" "---"
grep -qx 'name: taste-it' "$f" || fail "no name frontmatter"
grep -q '^description: .\{20,\}' "$f" || fail "no description frontmatter"
[[ $(sed -n '2,/^---$/p' "$f" | tail -1) == "---" ]] || fail "frontmatter not closed"
for l in $(grep -o '](\([^)#]*\))' "$f" | sed 's/](\(.*\))/\1/'); do
  [[ $l == http* ]] || [[ -f $SAMPLE/.claude/skills/taste-it/$l ]] || fail "broken link $l"; done
grep -q 'drivers.md' "$f" || fail "SKILL.md does not link drivers.md"
ctx=$(hook SessionStart st1 | jq -er .hookSpecificOutput.additionalContext) || fail "no additionalContext"
has ctx "$ctx" "taste-it"
line=$(grep '^\[ek\] Scenario runner: ' <<<"$ctx") || fail "no runner line in session context"
cmd=${line#"[ek] Scenario runner: "}
out=$(cd "$SAMPLE" && $cmd run 2>&1); eq "advertised runner rc" $? 2; has runner "$out" ".ek/scenarios/<slug>"
echo "taste-it ok"
