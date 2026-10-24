"""Scenario runner: `scenarios.py [--repo DIR] run [ID]|tree-hash|check|can-fail REF`.

Runs .ek/scenarios/<slug>/run.sh in fresh temp dirs; evidence goes to <git dir>/ek/ (or $EK_STATE/scenarios/<repo key>/).
Repo-local so the Stop hook (plugin env) and sandboxed Bash (read-only HOME) agree on one location.
"""
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time

LAYOUT = ".ek/scenarios/<slug>/SCENARIO.md + run.sh"
NODOC = "missing SCENARIO.md — document it (story, covers, steps, expected)"


def git(repo, *args):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def blob(p):
    """content id of one untracked path; never raises (symlink -> target, dir -> marker)."""
    try:
        if os.path.islink(p):
            return "link:" + os.readlink(p)
        if os.path.isdir(p):
            return "dir"
        with open(p, "rb") as f:
            return hashlib.sha1(f.read()).hexdigest()
    except OSError as e:
        return "err:" + e.strerror


def special(p):
    """device/fifo/socket: e.g. /dev/null the sandbox mounts over absent config paths; not real work."""
    try:
        m = os.lstat(p).st_mode
    except OSError:
        return False
    return not (stat.S_ISREG(m) or stat.S_ISDIR(m) or stat.S_ISLNK(m))


def tree_hash(repo):
    untracked = [u for u in git(repo, "ls-files", "-z", "-o", "--exclude-standard").split("\0") if u]
    skip = {u for u in untracked if special(os.path.join(repo, u))}
    status = [e for e in git(repo, "status", "--porcelain=v1", "-z", "-uall").split("\0") if e and not (e[:2] == "??" and e[3:] in skip)]
    blobs = "".join(f"{u}\0{blob(os.path.join(repo, u))}\0" for u in untracked if u not in skip)
    parts = [git(repo, "rev-parse", "HEAD"), "\0".join(status), git(repo, "diff", "HEAD"), blobs]
    return hashlib.sha1("\0".join(parts).encode()).hexdigest()


def outdir(repo):
    if os.environ.get("EK_STATE"):
        key = hashlib.sha1(os.path.realpath(repo).encode()).hexdigest()[:12]
        return os.path.join(os.environ["EK_STATE"], "scenarios", key)
    gd = git(repo, "rev-parse", "--absolute-git-dir").strip()
    return os.path.join(gd or os.path.join(repo, ".git"), "ek")


def root(repo):
    return os.path.join(repo, ".ek", "scenarios")


def find(repo):
    base = root(repo)
    return sorted((os.path.relpath(d, base) for d, _, fs in os.walk(base) if "run.sh" in fs), key=lambda i: i.split("/"))


def timeout():
    try:
        return float(os.environ.get("EK_SCENARIO_TIMEOUT") or 300)
    except ValueError:
        return 300.0


def run_one(repo, sid, ids, tdir):
    d = os.path.join(root(repo), sid)
    res = {"id": sid, "exit": None, "duration": 0.0, "transcript": os.path.join(tdir, sid.replace("/", "__") + ".log")}
    if not os.path.isfile(os.path.join(d, "SCENARIO.md")):
        res.update(exit=1, reason=NODOC)
        out = err = b""
        cwd = ""
    else:
        parent = os.path.dirname(sid)
        env = dict(os.environ, EK_REPO=repo, EK_SCENARIO_DIR=d,
                   EK_PARENT_DIR=os.path.join(root(repo), parent) if parent in ids else "")
        cwd = tempfile.mkdtemp(prefix="ek-scenario-")
        t0 = time.time()
        limit = timeout()
        p = subprocess.Popen(["bash", os.path.join(d, "run.sh")], cwd=cwd, env=env, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, start_new_session=True)
        try:
            out, err = p.communicate(timeout=limit)
            res["exit"] = p.returncode
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, 9)
            out, err = p.communicate()
            res.update(exit=None, reason=f"timeout after {limit:g}s")
        finally:
            res["duration"] = round(time.time() - t0, 3)
            shutil.rmtree(cwd, ignore_errors=True)
        if res["exit"] and "reason" not in res:
            res["reason"] = f"exit {res['exit']}"
    with open(res["transcript"], "wb") as f:
        f.write(f"command: bash run.sh\nscenario: {d}\ncwd: {cwd}\n--- stdout ---\n".encode() + out
                + b"\n--- stderr ---\n" + err + f"\n--- exit: {res['exit'] if res['exit'] is not None else 'timeout'} ---\n".encode())
    return res


def cmd_run(repo, only=None):
    ids = find(repo)
    if not ids:
        print(f"no scenarios found. expected layout: {LAYOUT}")
        return 2
    if only:
        only = only.strip("/")
        ids = [i for i in ids if i == only or i.startswith(only + "/")]
        if not ids:
            print(f"no scenario '{only}' (or children) under .ek/scenarios/")
            return 2
    th = tree_hash(repo)
    out = outdir(repo)
    tdir = os.path.join(out, th)
    os.makedirs(tdir, exist_ok=True)
    results = [run_one(repo, sid, ids, tdir) for sid in ids]
    for r in results:
        print(f"FAIL {r['id']}: {r['reason']}" if r.get("reason") else f"PASS {r['id']}")
    doc = {"verdict": "PASS", "tree": th, "repo": os.path.realpath(repo), "filter": only or None, "scenarios": results}
    if any(r.get("reason") for r in results):
        doc["verdict"] = "FAIL"
    if tree_hash(repo) != th:
        doc.update(verdict="FAIL", reason="scenarios modified the repo: run in the temp cwd")
        print("FAIL: " + doc["reason"])
    with open(os.path.join(out, "results.json"), "w") as f:
        json.dump(doc, f, indent=1)
    print(f"{doc['verdict']}: {sum(not r.get('reason') for r in results)}/{len(results)} scenarios")
    return doc["verdict"] == "FAIL"


def cmd_can_fail(repo, ref=None):
    if not ref:
        usage()
    ids = find(repo)
    if not ids:
        print(f"no scenarios found. expected layout: {LAYOUT}")
        return 2
    tmp = tempfile.mkdtemp(prefix="ek-canfail-")
    wt = os.path.join(tmp, "wt")
    try:
        r = subprocess.run(["git", "-C", repo, "worktree", "add", "--detach", wt, ref], capture_output=True, text=True)
        if r.returncode:
            print(f"cannot create worktree at {ref}: {r.stderr.strip()}")
            return 2
        shutil.rmtree(root(wt), ignore_errors=True)
        shutil.copytree(root(repo), root(wt))
        flagged = 0
        for sid in ids:
            res = run_one(wt, sid, ids, tmp)
            if res.get("reason"):
                print(f"CAN-FAIL ✓ {sid}")
            else:
                print(f"CANNOT FAIL {sid}: passes on baseline {ref}")
                flagged += 1
        return flagged > 0
    finally:
        subprocess.run(["git", "-C", repo, "worktree", "remove", "--force", wt], capture_output=True)
        shutil.rmtree(tmp, ignore_errors=True)
        subprocess.run(["git", "-C", repo, "worktree", "prune"], capture_output=True)


def cmd_hash(repo):
    print(tree_hash(repo))
    return 0


def cmd_check(repo):
    if not os.path.isdir(root(repo)):
        print(f"no scenarios. expected layout: {LAYOUT}")
        return 2
    try:
        with open(os.path.join(outdir(repo), "results.json")) as f:
            res = json.load(f)
    except (OSError, ValueError):
        print("no results: run scenarios")
        return 1
    if res.get("verdict") != "PASS":
        print("last run FAIL")
    elif res.get("filter"):
        print(f"partial run: only '{res['filter']}' was run; run all scenarios")
    elif res.get("tree") != tree_hash(repo):
        print("stale: tree changed since run")
    else:
        return 0
    return 1


def usage():
    print("usage: scenarios.py [--repo DIR] run [ID]|tree-hash|check|can-fail REF", file=sys.stderr)
    sys.exit(2)


def main():
    a = sys.argv[1:]
    repo = "."
    if "--repo" in a:
        i = a.index("--repo")
        if i + 1 >= len(a):
            usage()
        repo = a[i + 1]
        del a[i:i + 2]
    top = git(repo, "rev-parse", "--show-toplevel").strip()
    repo = top or os.path.abspath(repo)
    cmds = {"run": cmd_run, "tree-hash": cmd_hash, "check": cmd_check, "can-fail": cmd_can_fail}
    if not a or a[0] not in cmds:
        usage()
    sys.exit(cmds[a[0]](repo, *a[1:2]) if a[0] in ("run", "can-fail") else cmds[a[0]](repo))


if __name__ == "__main__":
    main()
