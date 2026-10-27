"""Mechanical review engine: git access, checks, contract envelope."""
import hashlib
import json
import os
import subprocess
from collections import namedtuple

from .stack import ADAPTERS

PLUGIN = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".claude-plugin", "plugin.json"))
CHECKS = ("R1", "R2", "R3", "R4")
Change = namedtuple("Change", "status old new")


class Die(Exception):
    """usage or git error: CLI exits 2."""


def ek_version():
    with open(PLUGIN) as f:
        return json.load(f)["version"]


def git(repo, *args):
    r = subprocess.run(["git", "-c", "core.quotepath=off", "-C", repo, *args], capture_output=True)
    if r.returncode:
        raise Die(r.stderr.decode("utf-8", "replace").strip() or f"git {args[0]} failed")
    return r.stdout.decode("utf-8", "replace")


def resolve(repo, ref):
    try:
        return git(repo, "rev-parse", "--verify", "-q", ref + "^{commit}").strip()
    except Die:
        raise Die(f"unknown ref: {ref}")


def entry(check, file, line, key, cls, severity, problem, hint, forbidden):
    """id = <check>-<sha1(check+file+key)[:8]>; key is the test fn or rule name, never a line number."""
    eid = f"{check}-" + hashlib.sha1((check + file + key).encode()).hexdigest()[:8]
    return {"id": eid, "check": check, "class": cls, "severity": severity, "file": file, "line": line,
            "problem": problem, "hint": hint, "forbidden": forbidden}


def finalize(entries):
    seen, out = set(), []
    for e in entries:
        if e["id"] not in seen:
            seen.add(e["id"])
            out.append(e)
    # file-level entries (line 0) sort after line-anchored ones within a file
    return sorted(out, key=lambda e: (e["file"], e["line"] == 0, e["line"], e["id"]))


def changes(repo, mb, head):
    toks = git(repo, "diff", "--no-ext-diff", "--no-textconv", "-z", "--name-status", "-M", mb, head).split("\0")
    out, i = [], 0
    while i < len(toks) and toks[i]:
        st = toks[i][0]
        if st in "RC":
            old, new, i = toks[i + 1], toks[i + 2], i + 3
        else:
            old = new = toks[i + 1]
            i += 2
        out.append(Change(st, None if st == "A" else old, None if st == "D" else new))
    return out


def blob(repo, rev, path):
    return git(repo, "cat-file", "blob", f"{rev}:{path}")


def r2(repo, mb, head, adapter, test_globs):
    entries = []
    for ch in changes(repo, mb, head):
        path = ch.new or ch.old
        if adapter.classify(path, test_globs) is None:
            continue
        before = blob(repo, mb, ch.old) if ch.old else None
        after = blob(repo, head, ch.new) if ch.new else None
        bfns = adapter.test_fns(before) if before is not None else []
        afns = adapter.test_fns(after) if after is not None else []
        names = {f.name for f in afns}
        by_name = {f.name: f for f in bfns}
        for f in bfns:
            if f.name not in names:
                entries.append(entry("R2", path, f.line, f.name, "agent-fixable", "fail",
                                     f"test fn `{f.name}` removed",
                                     "restore the test and make the code satisfy it; a removed test is not a fix",
                                     "deleting or renaming a test to hide a failure"))
        for f in afns:
            old = by_name.get(f.name)
            if "ignore" in f.markers and not (old and "ignore" in old.markers):
                entries.append(entry("R2", path, f.line, f.name, "agent-fixable", "fail",
                                     f"test `{f.name}` marked #[ignore]",
                                     "make it pass or fix the code it covers; do not mark it ignored",
                                     "#[ignore] / skip / xfail / only on a test"))
        if before is not None:
            whole = adapter.classify(path, test_globs) == "test"
            nb = sum(1 for a in adapter.assertions(before) if whole or a.fn)
            na = sum(1 for a in (adapter.assertions(after) if after is not None else []) if whole or a.fn)
            if na < nb:
                entries.append(entry("R2", path, 0, "assert-count", "agent-fixable", "fail",
                                     f"assertions in `{path}` dropped from {nb} to {na}",
                                     "restore the dropped assertions; strengthen a test instead of removing one",
                                     f"fewer asserts in changed test file {path}"))
    return entries


def envelope(base, head, entries):
    fails = [e for e in entries if e["severity"] == "fail"]
    confirms = [e for e in entries if e["severity"] == "confirm"]
    checks = {c: {"status": "skipped", "note": "not implemented"} for c in CHECKS}
    checks["R2"] = {"status": "fail" if fails else "pass", "note": f"{len(fails)} fail, {len(confirms)} confirm"}
    if not entries:
        summary = f"all pass {head}"
    else:
        verdict = "fail" if fails else "confirm"
        summary = f"{verdict} {head} ({len(fails)} fail, {len(confirms)} confirm)"
    return {"ek": ek_version(), "base": base, "head": head, "checks": checks, "entries": entries, "summary": summary}


def run(repo, base_ref, head_ref, stack, test_globs):
    base = resolve(repo, base_ref)
    head = resolve(repo, head_ref)
    try:
        mb = git(repo, "merge-base", base, head).strip()
    except Die:
        raise Die(f"no merge base for {base_ref} and {head_ref}")
    adapter = ADAPTERS[stack]()
    entries = finalize(r2(repo, mb, head, adapter, test_globs))
    return envelope(base, head, entries)
