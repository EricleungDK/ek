"""The contract envelope: entries and their ids, the one-line summary, the plugin version."""
import hashlib
import json
import os

PLUGIN = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".claude-plugin", "plugin.json"))
CHECKS = ("R1", "R2", "R3", "R4")


def ekit_version():
    with open(PLUGIN) as f:
        return json.load(f)["version"]


def entry(check, file, line, key, cls, severity, problem, hint, forbidden):
    """key: test fn or rule name (never a line number); the id is assigned in finalize."""
    return {"id": "", "check": check, "class": cls, "severity": severity, "file": file, "line": line,
            "problem": problem, "hint": hint, "forbidden": forbidden, "_key": key}


def finalize(entries):
    """id = <check>-<sha1(check+file+key)[:8]>. The n-th entry (line order, n>=1) with the same check+file+key
    gets key '#n' so repeats are kept; n=0 keeps the plain id. Line numbers never enter an id."""
    groups = {}
    for e in entries:
        groups.setdefault((e["check"], e["file"], e["_key"]), []).append(e)
    out = []
    for (check, file, key), group in groups.items():
        group.sort(key=lambda e: (e["line"] == 0, e["line"]))
        for n, e in enumerate(group):
            k = key if n == 0 else f"{key}#{n}"
            e["id"] = f"{check}-" + hashlib.sha1((check + file + k).encode("utf-8", "surrogateescape")).hexdigest()[:8]
            del e["_key"]
            out.append(e)
    # file-level entries (line 0) sort after line-anchored ones within a file
    return sorted(out, key=lambda e: (e["file"], e["line"] == 0, e["line"], e["id"]))


def _partial_label(check, name):
    """`R3 (tested/total)`; `?` when the total is unknown (budget hit before the mutant list was written)."""
    if check.get("tested") is None:
        return name
    total = check["total"] if check["total"] is not None else "?"
    return f"{name} ({check['tested']}/{total})"


def summarize(head, checks, entries):
    """`all pass <head>` only when every check passed and there are no entries. Otherwise
    `<pass|fail> <head> (<F> fail, <C> confirm; ran: <checks>[; skipped: <checks>][; n/a: <checks>])`.
    n/a (toolchain absent) is not ran and not skipped: it is named so it never reads as a pass."""
    fails = sum(1 for e in entries if e["severity"] == "fail")
    confirms = len(entries) - fails
    if not entries and all(checks[c]["status"] == "pass" for c in CHECKS):
        return f"all pass {head}"
    skipped = [c for c in CHECKS if checks[c]["status"] == "skipped"]
    na = [c for c in CHECKS if checks[c]["status"] == "n/a"]
    partial = [c for c in CHECKS if checks[c]["status"] == "partial"]
    ran = [c for c in CHECKS if c not in skipped and c not in na]
    parts = f"{fails} fail, {confirms} confirm; ran: {' '.join(ran) or 'none'}"
    if partial:
        parts += "; partial: " + " ".join(_partial_label(checks[c], c) for c in partial)
    if skipped:
        parts += f"; skipped: {' '.join(skipped)}"
    if na:
        parts += f"; n/a: {' '.join(na)}"
    return f"{'fail' if fails else 'pass'} {head} ({parts})"


def envelope(base, head, entries, checks):
    return {"ekit": ekit_version(), "base": base, "head": head, "checks": checks, "entries": entries,
            "summary": summarize(head, checks, entries)}
