"""Stop/SubagentStop hook: block until the finish report is given. Orchestrate-only:
silent unless the session was armed by a prompt starting with /ek:orchestrate-agent (or /orchestrate-agent).

Plain repo: block once per new uncommitted change set.
Repo with .ek/scenarios/: block while scenarios.py `check` isn't a fresh PASS for the current tree
(committed work counts; stale/failing keeps blocking; stop_hook_active is the loop guard).
Allowed when the runner tree-hash is unchanged since session start (no work done; baseline is per repo).
Runner errors fail closed (block). Test seam: EK_SCENARIOS_PY overrides the runner path.

`finish-gate.py --baseline` (stdin: hook payload) records the tree state at session start instead.
`finish-gate.py --arm` (UserPromptSubmit payload) arms the session when the prompt invokes orchestrate-agent.
"""
import hashlib
import json
import os
import re
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


SCEN = os.environ.get("EK_SCENARIOS_PY") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "scenarios.py")


def runner(repo, cmd):
    r = subprocess.run([sys.executable, "-I", SCEN, "--repo", repo, cmd], capture_output=True, text=True)
    return r.returncode, (r.stdout.strip() or r.stderr.strip())


def scenario_gate(data, session, top):
    """Gate for repos with .ek/scenarios/; returns True if handled."""
    if not top or not os.path.isdir(os.path.join(top, ".ek", "scenarios")):
        return False
    rc, cur = runner(top, "tree-hash")
    sbase = path(session, "sbase-" + hashlib.sha1(os.path.realpath(top).encode()).hexdigest()[:12])
    if "--baseline" in sys.argv:
        if read(sbase) is None:
            write(sbase, cur if rc == 0 else "")
        return True
    if data.get("stop_hook_active") or (rc == 0 and cur == read(sbase)):
        return True
    err = None
    if rc != 0:
        err = cur.splitlines()[0] if cur else f"exit {rc}"
    else:
        rc, why = runner(top, "check")
        if rc == 0:
            return True
        if rc != 1:
            err = why.splitlines()[0] if why else f"exit {rc}"
    head = f"scenario runner error: {err}" if err else f"Scenarios not green: {why}"
    print(json.dumps({
        "decision": "block",
        "reason": f"[ek] {head}. Run `python3 {SCEN} --repo {top} run` "
                  "and follow the taste-it skill (ek:taste-it). "
                  "Then give the finish report (finish skill): each criterion with evidence, "
                  "verification debt, and what stays uncommitted and why. Then stop.",
    }))
    return True


ARM = re.compile(r"(?:\A\s*|<command-name>)/(?:ek:)?orchestrate-agent(?![\w-])")


def main():
    data = json.load(sys.stdin)
    session, cwd = data.get("session_id", "none"), data.get("cwd") or os.getcwd()
    if "--arm" in sys.argv:
        if ARM.search(data.get("prompt") or ""):
            write(path(session, "armed"), "1")
        return
    if "--baseline" not in sys.argv and read(path(session, "armed")) is None:
        return
    top = (git(cwd, "rev-parse", "--show-toplevel") or "").strip()
    if scenario_gate(data, session, top):
        return
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
