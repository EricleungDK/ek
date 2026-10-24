source "$(dirname "$0")/lib.sh"
PF="$ROOT/scripts/preflight.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

run() { PATH="$1" HOME="$T/home" bash "$PF" "$2" 2>&1; }

# bare python missing, python3 present
B="$T/b1"; fakebin "$B" python3; P="$T/p1"; mkdir -p "$P"
out="$(run "$B" "$P")"
has "$out" "python: missing → use python3" "bare python missing → fallback python3"
has "$out" "jq: missing → python3 -c 'import json'" "jq missing → fallback"
has "$out" "rg: missing → grep -rn / find" "rg missing → fallback"
lacks "$out" "cargo" "no Cargo.toml → no cargo check"
lacks "$out" "docker" "no Dockerfile → no docker check"

# all present → quiet output only has ok lines; --quiet prints nothing
B="$T/b2"; fakebin "$B" python3 jq; stub "$B" python 'exec python3 "$@"'; stub "$B" rg 'exit 0'
out="$(PATH="$B" HOME="$T/home" bash "$PF" --quiet "$P" 2>&1)"
eq "$out" "" "--quiet with nothing wrong prints nothing"

# python project without .venv
P="$T/p3"; mkdir -p "$P"; touch "$P/pyproject.toml"
out="$(run "$T/b2" "$P")"
has "$out" "venv: no .venv → uv sync, then uv run <cmd>" "pyproject without .venv"
mkdir "$P/.venv"; out="$(run "$T/b2" "$P")"
lacks "$out" "venv:" ".venv present → no warning"

# rust project without cargo
P="$T/p4"; mkdir -p "$P"; touch "$P/Cargo.toml"
out="$(run "$T/b2" "$P")"
has "$out" "cargo: missing → Cargo.toml present; rust build/test can't run here" "Cargo.toml without cargo"

# node engines mismatch
P="$T/p5"; mkdir -p "$P"; echo '{"engines":{"node":">=22"}}' > "$P/package.json"
B="$T/b5"; fakebin "$B" python3 jq; stub "$B" node 'echo v20.1.0'
out="$(run "$B" "$P")"
has "$out" "node: v20.1.0 < engines >=22 → nvm use 22" "node below engines"
stub "$B" node 'echo v24.0.0'; out="$(run "$B" "$P")"
lacks "$out" "node:" "node satisfies engines"

# docker project, docker unusable
P="$T/p6"; mkdir -p "$P"; touch "$P/docker-compose.yml"
B="$T/b6"; fakebin "$B" python3 jq; stub "$B" docker 'echo "permission denied while trying to connect to the Docker daemon socket" >&2; exit 1'
out="$(run "$B" "$P")"
has "$out" "docker: unusable (permission denied" "docker perm denied surfaced"
has "$out" "container tests → verification debt" "docker fallback stated"

# playwright project, no chromium
P="$T/p7"; mkdir -p "$P"; echo '{"devDependencies":{"@playwright/test":"1.0"}}' > "$P/package.json"
out="$(run "$T/b2" "$P")"
has "$out" "playwright: no chromium in ~/.cache/ms-playwright or \$CHROME_BIN → npx playwright install chromium" "playwright no browser"
mkdir -p "$T/home/.cache/ms-playwright/chromium-1/chrome-linux64"; touch "$T/home/.cache/ms-playwright/chromium-1/chrome-linux64/chrome"
out="$(run "$T/b2" "$P")"
lacks "$out" "playwright:" "chromium found in cache"

# gh present but not authed
B="$T/b8"; fakebin "$B" python3 jq; stub "$B" gh '[[ $1 == auth ]] && exit 1; exit 0'
out="$(run "$B" "$T/p1")"
has "$out" "gh: not authed → user runs: ! gh auth login" "gh unauthed"
has "$out" "gh issue view: always pass --json" "gh --json gotcha"

# .git read-only
P="$T/p9"; mkdir -p "$P/.git"; chmod a-w "$P/.git"
out="$(run "$T/b2" "$P")"
has "$out" "git: .git read-only (sandbox) → commits need unsandboxed run" ".git read-only"
chmod u+w "$P/.git"

# loopback bind blocked (stub python3 failing bind probe)
B="$T/b10"; fakebin "$B" jq; stub "$B" python3 '[[ "$*" == *bind* ]] && { echo "PermissionError: [Errno 1] Operation not permitted" >&2; exit 1; }; exit 0'
out="$(run "$B" "$T/p1")"
has "$out" "loopback: bind 127.0.0.1 blocked (sandbox) → server/e2e tests need unsandboxed run" "loopback blocked"

# scenarios marker: missing driver tools warn
P="$T/p11"; mkdir -p "$P/.ek/scenarios/a"
out="$(run "$T/b2" "$P")"
for t in tmux expect curl; do
  has "$out" "$t: missing → scenarios needing $t can't run here → human verdict / verification debt" "scenarios + no $t"
done
B="$T/b11"; fakebin "$B" python3 jq; for t in tmux expect curl; do stub "$B" $t "exit 0"; done
out="$(run "$B" "$P")"
lacks "$out" "tmux:" "tmux present → no warning"
lacks "$out" "expect:" "expect present → no warning"
lacks "$out" "curl:" "curl present → no warning"
out="$(run "$T/b2" "$T/p1")"
lacks "$out" "tmux:" "no scenarios → no tmux check"
lacks "$out" "curl:" "no scenarios → no curl check"
out="$(PATH="$B" HOME="$T/home" bash "$PF" --quiet "$P" 2>&1)"
lacks "$out" "ok tmux" "--quiet hides ok driver lines"
out="$(run "$B" "$P")"
has "$out" "ok tmux" "driver present → ok line"

# playwright check also applies when scenarios exist (no playwright dep)
rm -rf "$T/home/.cache"
P="$T/p12"; mkdir -p "$P/.ek/scenarios/a"
out="$(run "$T/b2" "$P")"
has "$out" "playwright: no chromium" "scenarios trigger playwright check"
P="$T/p13"; mkdir -p "$P"
out="$(run "$T/b2" "$P")"
lacks "$out" "playwright:" "no marker → no playwright check"

done_tests
