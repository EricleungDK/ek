source "$(dirname "$0")/lib.sh"
FM="$ROOT/scripts/failure-match.py"

# feed <command> <error>: run hook with a PostToolUseFailure payload
feed() { jq -nc --arg c "$1" --arg e "$2" '{hook_event_name:"PostToolUseFailure",tool_name:"Bash",tool_input:{command:$c},error:$e}' | SS_STUB="${SS_STUB:-}" python3 -I "$FM"; }
ctx()  { jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$1"; }

out="$(feed "npx playwright test" $'Exit code 1\nError: listen EPERM: operation not permitted 127.0.0.1:8917')"
has "$(ctx "$out")" "sandbox/env" "listen EPERM → sandbox/env"
has "$(ctx "$out")" "rerun once unsandboxed" "sandbox → rerun unsandboxed"
eq "$(jq -r .hookSpecificOutput.hookEventName <<<"$out")" "PostToolUseFailure" "event name echoed"

out="$(feed "git commit -m x" $'Exit code 128\nfatal: Unable to create \'.git/index.lock\': Read-only file system')"
has "$(ctx "$out")" "sandbox/env" "EROFS .git → sandbox/env"

out="$(feed "docker ps" $'Exit code 1\npermission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock')"
has "$(ctx "$out")" "sandbox/env" "docker.sock → sandbox/env"

out="$(feed "git fetch" $'Exit code 128\nfatal: unable to access: Could not resolve host: github.com')"
has "$(ctx "$out")" "sandbox/env" "DNS → sandbox/env"

out="$(SS_STUB='LISTEN 0 511 127.0.0.1:4321 0.0.0.0:* users:(("node",pid=777,fd=20))' feed "npm run dev" $'Exit code 1\nError: listen EADDRINUSE: address already in use 127.0.0.1:4321')"
has "$(ctx "$out")" "port 4321 held by pid 777 (node)" "port in use → owner pid"
has "$(ctx "$out")" "kill that exact PID only" "port → targeted kill"

out="$(feed "python -m pytest" $'Exit code 127\nbash: line 1: python: command not found')"
has "$(ctx "$out")" "python missing → python3" "python not found → fallback"
out="$(feed "rg foo" $'Exit code 127\nbash: rg: command not found')"
has "$(ctx "$out")" "rg missing → grep -rn" "rg not found → fallback"

out="$(feed "uv run pytest tests/test_x.py" $'Exit code 1\nFAILED tests/test_x.py::test_a - AssertionError')"
has "$(ctx "$out")" "failure-triage" "test red → triage pointer"
out="$(feed "cargo test" $'Exit code 101\ntest result: FAILED. 3 passed; 1 failed')"
has "$(ctx "$out")" "failure-triage" "cargo test red → triage pointer"

out="$(feed "ls /nope" $'Exit code 2\nls: cannot access \'/nope\': No such file or directory')"
eq "$out" "" "plain error → silent"

out="$(echo '{"hook_event_name":"PostToolUseFailure","tool_name":"Edit","error":"x"}' | python3 -I "$FM")"
eq "$out" "" "non-Bash tool → silent"

done_tests
