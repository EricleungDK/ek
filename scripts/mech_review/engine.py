"""Mechanical review engine: git access, checks, contract envelope."""
import json
import os
import subprocess

PLUGIN = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".claude-plugin", "plugin.json"))
CHECKS = ("R1", "R2", "R3", "R4")


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


def envelope(base, head, entries):
    fails = [e for e in entries if e["severity"] == "fail"]
    confirms = [e for e in entries if e["severity"] == "confirm"]
    checks = {c: {"status": "skipped", "note": "not implemented yet"} for c in CHECKS}
    checks["R2"] = {"status": "fail" if fails else "pass", "note": f"{len(fails)} fail, {len(confirms)} confirm"}
    if not entries:
        summary = f"all pass {head}"
    else:
        verdict = "fail" if fails else "confirm"
        summary = f"{verdict} {head} ({len(fails)} fail, {len(confirms)} confirm)"
    return {"ek": ek_version(), "base": base, "head": head, "checks": checks, "entries": entries, "summary": summary}


def run(repo, base_ref, head_ref):
    base = resolve(repo, base_ref)
    head = resolve(repo, head_ref)
    return envelope(base, head, [])
