source "$(dirname "$0")/lib.sh"
# Pre-rename (ek) repos keep working: .ek/scenarios/, EK_* scenario env, EK_STATE, EricleungDK/ek callers.
SC="$ROOT/scripts/scenarios.py"; SS="$ROOT/scripts/session-start.py"; FG="$ROOT/scripts/finish-gate.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
unset EKIT_STATE; export EK_STATE="$T/state"

mkrepo() { # mkrepo <dir> <layout dir> <run.sh body>
  mkdir -p "$1/$2/scenarios/x"; git -C "$1" init -q
  echo s > "$1/$2/scenarios/x/SCENARIO.md"; printf '#!/bin/bash\n%s\n' "$3" > "$1/$2/scenarios/x/run.sh"
  git -C "$1" add -A; git -C "$1" -c user.email=t@t -c user.name=t commit -q -m init
}

# runner finds .ek/scenarios; scenario sees both env names; EK_STATE honoured
L="$T/legacy"; mkrepo "$L" .ek 'echo "$EK_REPO|$EKIT_REPO|$EK_SCENARIO_DIR|$EKIT_SCENARIO_DIR" > "$EK_REPO/../env.out"'
out="$(python3 -I "$SC" --repo "$L" run 2>&1)"; rc=$?
eq "$rc" 0 "legacy .ek/scenarios: run exit 0"
has "$out" "PASS x" "legacy .ek/scenarios: PASS"
eq "$(cat "$T/env.out")" "$L|$L|$L/.ek/scenarios/x|$L/.ek/scenarios/x" "legacy: EK_* and EKIT_* both set"
key="$(printf %s "$(realpath "$L")" | sha1sum | cut -c1-12)"
[[ -f "$EK_STATE/scenarios/$key/results.json" ]] && ok "EK_STATE honoured" || fail "EK_STATE honoured"

# both layouts: .ekit wins
B="$T/both"; mkrepo "$B" .ek 'exit 1'; mkdir -p "$B/.ekit/scenarios/y"; echo s > "$B/.ekit/scenarios/y/SCENARIO.md"; echo 'exit 0' > "$B/.ekit/scenarios/y/run.sh"
out="$(python3 -I "$SC" --repo "$B" run 2>&1)"
has "$out" "PASS y" "both: .ekit runs"
lacks "$out" "x" "both: .ek ignored"

# finish gate engages on .ek/scenarios
F="$T/gate"; mkrepo "$F" .ek 'exit 1'
start() { jq -nc --arg c "$1" --arg s "$2" '{hook_event_name:"SessionStart",session_id:$s,cwd:$c,source:"startup"}' | python3 -I "$SS"; }
arm()   { jq -nc --arg c "$1" --arg s "$2" '{hook_event_name:"UserPromptSubmit",session_id:$s,cwd:$c,prompt:"/ekit:orchestrate-agent x"}' | python3 -I "$FG" --arm; }
stop()  { jq -nc --arg c "$1" --arg s "$2" '{hook_event_name:"Stop",session_id:$s,cwd:$c,stop_hook_active:false}' | python3 -I "$FG"; }
start "$F" g1 >/dev/null; arm "$F" g1 >/dev/null; echo a > "$F/a.txt"; python3 -I "$SC" --repo "$F" run >/dev/null
out="$(stop "$F" g1)"
eq "$(jq -r .decision <<<"$out")" "block" "legacy gate: failing scenario → block"
has "$(jq -r .reason <<<"$out")" "scenarios.py" "legacy gate: scenario reason"

# preflight sees .ek/scenarios
P="$T/pf"; mkdir -p "$P/.ek/scenarios/a"; Bn="$T/bin"; fakebin "$Bn" python3 jq
out="$(PATH="$Bn" HOME="$T/home" bash "$ROOT/scripts/preflight.sh" "$P" 2>&1)"
has "$out" "tmux: missing" "legacy preflight: scenario tools checked"

# doctor recognises an EricleungDK/ek caller
python3 -I - "$ROOT" <<'PY' && ok "doctor: legacy caller recognised" || fail "doctor: legacy caller recognised"
import sys; sys.path.insert(0, sys.argv[1] + "/scripts")
from mech_review import doctor
t = "jobs:\n  m:\n    uses: EricleungDK/ek/.github/workflows/mech-review.yml@v0\n    with:\n      stack: rust\n"
assert doctor.is_caller(t) and doctor.caller_inputs(t) == {"stack": "rust"}, doctor.caller_inputs(t)
assert doctor.is_caller(t.replace("/ek/", "/ekit/"))
assert not doctor.is_caller("uses: actions/checkout@v4")
PY

done_tests
