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

# --- scenario repos: gate on fresh runner PASS ---
SC="$ROOT/scripts/scenarios.py"
mkrepo() { # mkrepo <dir> <run.sh exit code>
  mkdir -p "$1/.ek/scenarios/x"; git -C "$1" init -q
  echo s > "$1/.ek/scenarios/x/SCENARIO.md"; printf '#!/bin/bash\nexit %s\n' "$2" > "$1/.ek/scenarios/x/run.sh"
  git -C "$1" add -A; git -C "$1" -c user.email=t@t -c user.name=t commit -q -m init
}
runsc() { python3 -I "$SC" --repo "$1" run >/dev/null; }
dec() { jq -r .decision <<<"$1"; }

P="$T/pass"; mkrepo "$P" 0
F="$T/fail"; mkrepo "$F" 1

# PASS current tree -> allow
start "$P" p1 >/dev/null; echo a > "$P/a.txt"; runsc "$P"
eq "$(stop "$P" p1)" "" "scenarios PASS fresh → allow"
# PASS then edit -> stale block, keeps blocking
echo b >> "$P/a.txt"
out="$(stop "$P" p1)"; eq "$(dec "$out")" "block" "PASS then edit → block"
has "$(jq -r .reason <<<"$out")" "stale" "block reason has check reason"
has "$(jq -r .reason <<<"$out")" "scenarios.py" "block reason points to runner"
has "$(jq -r .reason <<<"$out")" "ek:taste-it" "block reason points to taste-it"
has "$(jq -r .reason <<<"$out")" "finish" "block reason asks finish report"
eq "$(dec "$(stop "$P" p1)")" "block" "stale keeps blocking (no once-only)"
eq "$(stop "$P" p1 true)" "" "scenarios + stop_hook_active → allow"
eq "$(dec "$(stop "$P" p1 false SubagentStop)")" "block" "scenarios SubagentStop → block"

# no results -> block; failing results -> block
start "$F" f1 >/dev/null; echo a > "$F/a.txt"
out="$(stop "$F" f1)"; eq "$(dec "$out")" "block" "no results → block"
has "$(jq -r .reason <<<"$out")" "no results" "no-results reason"
runsc "$F"
out="$(stop "$F" f1)"; eq "$(dec "$out")" "block" "failing results → block"
has "$(jq -r .reason <<<"$out")" "FAIL" "fail reason"

# untouched since start -> allow (even with no results)
U="$T/untouched"; mkrepo "$U" 0
start "$U" u1 >/dev/null
eq "$(stop "$U" u1)" "" "scenario repo untouched → allow"

# commit after start without run -> block
echo c > "$U/c.txt"; git -C "$U" add -A; git -C "$U" -c user.email=t@t -c user.name=t commit -q -m c
eq "$(dec "$(stop "$U" u1)")" "block" "commit after start, no run → block"
runsc "$U"
eq "$(stop "$U" u1)" "" "commit then run PASS → allow"

# runner broken -> fail closed (stop_hook_active still allows)
printf 'import sys\nsys.stderr.write("boom\\n")\nsys.exit(3)\n' > "$T/badrunner"
E="$T/err"; mkrepo "$E" 0
EK_SCENARIOS_PY="$T/badrunner" start "$E" e1 >/dev/null
out="$(EK_SCENARIOS_PY="$T/badrunner" stop "$E" e1)"
eq "$(dec "$out")" "block" "runner error → block"
has "$(jq -r .reason <<<"$out")" "scenario runner error" "runner error reason"
has "$(jq -r .reason <<<"$out")" "boom" "runner error shows output"
eq "$(EK_SCENARIOS_PY="$T/badrunner" stop "$E" e1 true)" "" "runner error + stop_hook_active → allow"

# baseline is per repo within one session
A2="$T/a2"; B2="$T/b2"; mkrepo "$A2" 0; mkrepo "$B2" 0; echo b > "$B2/b.txt"
start "$A2" m1 >/dev/null; start "$B2" m1 >/dev/null
eq "$(stop "$B2" m1)" "" "second repo own baseline → allow"
eq "$(stop "$A2" m1)" "" "first repo own baseline → allow"

done_tests
