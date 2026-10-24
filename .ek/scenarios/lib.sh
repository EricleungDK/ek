# shared helpers for ek dogfood scenarios (sourced; not a scenario). Needs EK_REPO, cwd = temp dir.
set -u
fail() { echo "ASSERT FAILED: $*" >&2; exit 1; }
eq() { [[ "$2" == "$3" ]] || fail "$1: expected [$3] got [$2]"; }
has() { [[ "$2" == *"$3"* ]] || fail "$1: expected output to contain [$3], got [$2]"; }
hasnt() { [[ "$2" != *"$3"* ]] || fail "$1: output must not contain [$3], got [$2]"; }
export EK_STATE="$PWD/state"; mkdir -p "$EK_STATE"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
OLDHOME="$HOME"; export HOME="$PWD/home"; mkdir -p "$HOME"
RUNNER="$EK_REPO/scripts/scenarios.py"
# sample git repo, no kit yet
mk_repo() { SAMPLE="$PWD/sample"; rm -rf "$SAMPLE"; mkdir -p "$SAMPLE"; git -C "$SAMPLE" init -q -b main
  echo "print('hi')" > "$SAMPLE/app.py"; git -C "$SAMPLE" add -A; git -C "$SAMPLE" commit -qm init; }
# real user install (cloud installer) into the sample repo
install_kit() { bash "$EK_REPO/cloud/install.sh" "$SAMPLE" >/dev/null || fail "install.sh failed"
  [[ -f $SAMPLE/.claude/settings.json ]] || fail "no .claude/settings.json after install"; }
# add a scenario to the sample: add_scn <id> <exit-code> [documented=1]
add_scn() { local d="$SAMPLE/.ek/scenarios/$1"; mkdir -p "$d"
  printf '#!/bin/bash\necho scenario-%s\nexit %s\n' "$1" "$2" > "$d/run.sh"
  [[ "${3:-1}" == 1 ]] && printf '# %s\n- story: s\n- covers: c\n- steps: x\n- expected: y\n' "$1" > "$d/SCENARIO.md"; return 0; }
commit_all() { git -C "$SAMPLE" add -A; git -C "$SAMPLE" commit -qm "${1:-c}"; }
# the installed hook command for an event, read from the sample's settings.json
hook_cmd() { jq -er --arg e "$1" '.hooks[$e][0].hooks[0].command' "$SAMPLE/.claude/settings.json" || fail "no $1 hook installed"; }
# run installed hook: hook <event> <session> [stop_hook_active]
hook() { local p; p=$(jq -nc --arg s "$2" --arg c "$SAMPLE" --argjson a "${3:-false}" '{session_id:$s,cwd:$c,hook_event_name:"x",stop_hook_active:$a}')
  (cd "$SAMPLE" && printf '%s' "$p" | bash -c "$(hook_cmd "$1")"); }
