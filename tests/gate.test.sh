source "$(dirname "$0")/lib.sh"
SS="$ROOT/scripts/session-start.py"; FG="$ROOT/scripts/finish-gate.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export EK_STATE="$T/state"

R="$T/repo"; mkdir -p "$R"; git -C "$R" init -q; git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
start() { jq -nc --arg c "$1" --arg s "$2" '{hook_event_name:"SessionStart",session_id:$s,cwd:$c,source:"startup"}' | python3 -I "$SS"; }
stop()  { jq -nc --arg c "$1" --arg s "$2" --argjson a "${3:-false}" --arg e "${4:-Stop}" '{hook_event_name:$e,session_id:$s,cwd:$c,stop_hook_active:$a}' | python3 -I "$FG"; }

# session start: pointers + guardrails injected
out="$(start "$R" s1)"
c="$(jq -r .hookSpecificOutput.additionalContext <<<"$out")"
has "$c" "failure-triage" "start → triage pointer"
has "$c" "finish" "start → finish pointer"
has "$c" "Same blocker 3×" "start → blocker guardrail"
has "$c" "exact command" "start → rephrase guardrail"

# clean tree → allow stop
eq "$(stop "$R" s1)" "" "clean tree → allow"

# change after start → block once, then allow same change set
echo x > "$R/a.txt"
out="$(stop "$R" s1)"
eq "$(jq -r .decision <<<"$out")" "block" "new change → block"
has "$(jq -r .reason <<<"$out")" "finish" "block reason points to finish"
has "$(jq -r .reason <<<"$out")" "a.txt" "block reason lists changed files"
eq "$(stop "$R" s1)" "" "same change set → allow (no loop)"
echo y >> "$R/a.txt"
eq "$(jq -r .decision <<<"$(stop "$R" s1)")" "block" "further change → block again"

# stop_hook_active → always allow
echo z >> "$R/a.txt"
eq "$(stop "$R" s1 true)" "" "stop_hook_active → allow"

# pre-existing dirt at session start → not gated
start "$R" s2 >/dev/null
eq "$(stop "$R" s2)" "" "dirt present at session start → allow"

# SubagentStop gated the same way
echo w > "$R/b.txt"
eq "$(jq -r .decision <<<"$(stop "$R" s2 false SubagentStop)")" "block" "SubagentStop → block"

# non-git dir → allow
mkdir -p "$T/plain"; start "$T/plain" s3 >/dev/null
eq "$(stop "$T/plain" s3)" "" "non-git → allow"

# preflight warnings included, e.g. Cargo.toml without cargo (PATH stripped)
B="$T/bin"; fakebin "$B" python3 git jq; touch "$T/plain/Cargo.toml"
c="$(jq -nc --arg c "$T/plain" '{session_id:"s4",cwd:$c,source:"startup"}' | PATH="$B" python3 -I "$SS" | jq -r .hookSpecificOutput.additionalContext)"
has "$c" "cargo: missing" "start → preflight warnings"

done_tests
