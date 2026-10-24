source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export EK_STATE_DIR="$T/state" XDG_STATE_HOME="$T/state" HOME="$T/home"; mkdir -p "$HOME"
R="$T/repo"; mkdir -p "$R"; git -C "$R" init -q

out="$(echo "{\"cwd\":\"$R\"}" | python3 -I "$ROOT/scripts/session-start.py")"
ctx="$(jq -r .hookSpecificOutput.additionalContext <<<"$out")"
has "$ctx" "[ek] Scenario runner: python3 $ROOT/scripts/scenarios.py" "runner line, absolute path"
has "$ctx" "taste-it" "rules mention taste-it"

# cloud install: hook command from settings.json yields the kit's absolute runner path
bash "$ROOT/cloud/install.sh" "$R" >/dev/null
cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$R/.claude/settings.json")"
ctx2="$(echo "{\"cwd\":\"$R\"}" | bash -c "$cmd" | jq -r .hookSpecificOutput.additionalContext)"
has "$ctx2" "python3 $ROOT/scripts/scenarios.py" "cloud install: runner path resolves to kit"

# runner line is executable from the cloud install, against the repo
runner="$(grep -o 'python3 [^ ]*scenarios.py' <<<"$ctx2")"
export EK_STATE="$T/ekstate"
mkdir -p "$R/.ek/scenarios/hello"; echo '# s' > "$R/.ek/scenarios/hello/SCENARIO.md"; printf '#!/bin/bash\nexit 0\n' > "$R/.ek/scenarios/hello/run.sh"
rout="$(cd "$R" && $runner run 2>&1)"; has "$rout" "PASS hello" "runner line runs scenarios"
(cd "$R" && $runner check >/dev/null 2>&1) && ok "runner check passes" || fail "runner check passes"

done_tests
