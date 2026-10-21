"""Stop/SubagentStop hook: block once per new change set until the finish report is given.

`finish-gate.py --baseline` (stdin: hook payload) records the tree state at session start instead.
"""
import hashlib
import json
import os
import subprocess
import sys

STATE = os.environ.get("EK_STATE") or os.path.join(
    os.environ.get("CLAUDE_PLUGIN_DATA") or os.path.expanduser("~/.cache/ek"), "state"
)


def git(cwd, *args):
    r = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def tree(cwd):
    """(hash, changed files) of uncommitted state, or None outside git / when clean."""
    status = git(cwd, "status", "--porcelain=v1", "-uall")
    if not status:
        return None
    diff = git(cwd, "diff", "HEAD") or ""
    untracked = (git(cwd, "ls-files", "-o", "--exclude-standard") or "").splitlines()
    blobs = (git(cwd, "hash-object", "--", *untracked) or "") if untracked else ""
    files = [line[3:] for line in status.splitlines()]
    return hashlib.sha1((status + diff + blobs).encode()).hexdigest(), files


def path(session, kind):
    os.makedirs(STATE, exist_ok=True)
    return os.path.join(STATE, f"{session}.{kind}")


def read(p):
    try:
        with open(p) as f:
            return f.read()
    except OSError:
        return None


def write(p, v):
    with open(p, "w") as f:
        f.write(v)


def main():
    data = json.load(sys.stdin)
    session, cwd = data.get("session_id", "none"), data.get("cwd") or os.getcwd()
    t = tree(cwd)
    if "--baseline" in sys.argv:
        base = path(session, "base")
        if read(base) is None:
            write(base, t[0] if t else "")
        return
    if data.get("stop_hook_active") or not t:
        return
    h, files = t
    gated = path(session, "gated")
    if h in (read(path(session, "base")), read(gated)):
        return
    write(gated, h)
    shown = ", ".join(files[:10]) + (f" (+{len(files) - 10} more)" if len(files) > 10 else "")
    print(json.dumps({
        "decision": "block",
        "reason": f"[ek] Uncommitted changes since session start: {shown}. "
                  "Before ending, give the finish report (finish skill): each criterion with evidence, "
                  "verification debt, and what stays uncommitted and why. Then stop.",
    }))


if __name__ == "__main__":
    main()
