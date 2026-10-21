"""PostToolUseFailure hook: classify known Bash failure signatures into one context line. Silent otherwise."""
import json
import os
import re
import subprocess
import sys

ENV = re.compile(
    r"EPERM|Operation not permitted|EROFS|Read-only file system|docker\.sock|"
    r"Could not resolve host|ENOTFOUND|EAI_AGAIN|Temporary failure in name resolution",
    re.I,
)
PORT = re.compile(r"EADDRINUSE|address already in use", re.I)
NOT_FOUND = re.compile(r"(?:^|\s)([\w.-]+): command not found")
FALLBACK = {"python": "python3", "rg": "grep -rn / find", "jq": "python3 -c 'import json'", "pip": "uv pip / python3 -m pip"}
TEST_CMD = re.compile(r"\b(pytest|vitest|jest|playwright test|cargo test|go test|npm (run )?test|pnpm test|yarn test|bun test|unittest)\b")


def listeners(port):
    out = os.environ.get("SS_STUB") or subprocess.run(
        ["ss", "-ltnpH", f"sport = :{port}"], capture_output=True, text=True
    ).stdout
    m = re.search(r'\("([^"]+)",pid=(\d+)', out)
    return m and (m.group(2), m.group(1))


def classify(cmd, err):
    if PORT.search(err):
        m = re.search(r":(\d{2,5})\b", err)
        port = m and m.group(1)
        owner = port and listeners(port)
        held = f"port {port} held by pid {owner[0]} ({owner[1]})" if owner else f"port {port or '?'} in use"
        return f"[ek] stale: {held}. If it's a dev server you started, kill that exact PID only; otherwise use another port."
    if ENV.search(err):
        return ("[ek] sandbox/env failure, not a code bug. Leave code as is; rerun once unsandboxed/escalated "
                "and record 'passed only unsandboxed', or log it as verification debt.")
    m = NOT_FOUND.search(err)
    if m:
        tool = m.group(1)
        return f"[ek] {tool} missing → {FALLBACK.get(tool, 'find an installed alternative or log as verification debt')}."
    if TEST_CMD.search(cmd):
        return "[ek] test red. Before editing code, classify it with the failure-triage skill."
    return None


def main():
    data = json.load(sys.stdin)
    if data.get("tool_name") != "Bash":
        return
    msg = classify(data.get("tool_input", {}).get("command", ""), data.get("error") or "")
    if msg:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUseFailure", "additionalContext": msg}}))


if __name__ == "__main__":
    main()
