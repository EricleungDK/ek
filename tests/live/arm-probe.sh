#!/bin/bash
# Live probe (manual; not in tests/run.sh: needs claude auth, costs tokens).
# Records the UserPromptSubmit payload a real Claude Code session sends for /ek:orchestrate-agent,
# and checks the kit's --arm hook arms on it and not on a mid-prompt mention.
# Runs in a throwaway git worktree of HEAD, loaded via --plugin-dir; removed on exit.
# Usage: tests/live/arm-probe.sh [--tmux]   (--tmux: type the prompt into an interactive session)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"; WT="$T/wt"; OUT="$T/out"; mkdir -p "$OUT"
cleanup() { tmux kill-session -t ekprobe 2>/dev/null; git -C "$ROOT" worktree remove --force "$WT" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
git -C "$ROOT" worktree add -q --detach "$WT" HEAD || exit 2
export EK_STATE="$OUT/state"   # finish-gate writes <session>.armed here
cap="cat > \"$OUT/payload-\$(date +%s%N).json\""
SETTINGS=$(jq -nc --arg c "$cap" '{hooks:{UserPromptSubmit:[{hooks:[{type:"command",command:$c}]}]}}')
CL=(claude --plugin-dir "$WT" --settings "$SETTINGS")

probe() { # probe <label> <prompt>: one session, prints payload prompt + armed state
  rm -rf "$OUT"/payload-* "$EK_STATE"
  if [[ ${MODE:-print} == tmux ]]; then
    tmux new-session -d -s ekprobe -x 200 -y 50 -c "$WT" "$(printf '%q ' "${CL[@]}")"
    sleep 8; tmux send-keys -t ekprobe Enter; sleep 3   # accept trust dialog if shown
    tmux send-keys -t ekprobe -l "$2"; sleep 1; tmux send-keys -t ekprobe Enter
    for _ in $(seq 60); do compgen -G "$OUT/payload-*" >/dev/null && break; sleep 1; done
    sleep 2; tmux kill-session -t ekprobe 2>/dev/null
  else
    (cd "$WT" && timeout 180 "${CL[@]}" -p "$2" --max-turns 1 >/dev/null 2>&1)
  fi
  local p; p=$(ls "$OUT"/payload-* 2>/dev/null | head -1)
  echo "== $1"
  [[ -n $p ]] && echo "prompt: $(jq -c .prompt "$p")" || echo "prompt: <no payload captured>"
  compgen -G "$EK_STATE/*.armed" >/dev/null && echo "armed: yes" || echo "armed: no"
}

[[ ${1:-} == --tmux ]] && MODE=tmux
probe invoke "/ek:orchestrate-agent probe only: reply PROBE-OK and stop, do nothing else"
probe mention "what does /ek:orchestrate-agent do? one word"
