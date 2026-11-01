"""Merge the job results into one envelope for the sticky comment, and the mutants shards into the mutants job result.

Each job owns its checks: r2 owns R2, red owns R1 and R4, mutants owns R3. A job with no usable result (missing,
unreadable, or for another head) fails the checks it owns and adds one CI entry naming it, so a crash in one job
never hides the other job's entries. A job that was not run (no production file changed) is simply absent: its
checks stay skipped.
"""
import json

from .engine import CHECKS, entry, envelope, finalize

OWNS = {"r2": ("R2",), "red": ("R1", "R4"), "mutants": ("R3",)}


def merge(parts, reasons):
    """parts: {job: envelope or None}, reasons: {job: why it has no envelope}. At least one envelope is present."""
    present = [env for env in parts.values() if env is not None]
    if not present:
        raise ValueError("merge needs at least one envelope")
    first = present[0]
    checks = {c: {"status": "skipped", "note": "not run: no production file changed"} for c in CHECKS}
    kept, ci = [], []
    for job, env in parts.items():
        owned = OWNS[job]
        if env is None:
            why = reasons.get(job, "no usable result")
            for c in owned:
                checks[c] = {"status": "fail", "note": f"no result from {job} job: {why}"}
            ci.append(entry("CI", "", 0, f"no-result:{job}", "env", "fail",
                            f"{job} job produced no result: {why}",
                            "see the job log; the checks it owns did not run", "a merged result without that job"))
            continue
        for c in owned:
            checks[c] = env["checks"][c]
        kept += [e for e in env["entries"] if e["check"] in owned]
    ci = finalize(ci)
    entries = sorted(kept + ci, key=lambda e: (e["file"], e["line"] == 0, e["line"], e["id"]))
    return envelope(first["base"], first["head"], entries, checks)


def load_envelope(path):
    """The envelope dict at path, or None if missing, unreadable or not an envelope."""
    try:
        with open(path) as fh:
            env = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(env, dict) or not all(k in env for k in ("head", "summary", "entries", "checks")):
        return None
    return env


def combine_shards(base, head, n, shards, reasons):
    """The mutants job: R3 from n shard envelopes (0-based shard k of n). shards: {k: envelope or None},
    reasons: {k: why there is no envelope}. A missing shard fails R3 with a CI entry naming it; the other shards'
    entries stay. R3 status: fail > n/a > partial > skipped > pass. tested/total are summed over the shards."""
    checks = {c: {"status": "skipped", "note": "not run by mutants"} for c in CHECKS}
    kept, ci, notes, statuses = [], [], [], []
    tested = total = 0
    counted = unknown = False
    for k in range(n):
        label = f"{k}/{n}"
        env = shards.get(k)
        if env is None:
            why = reasons.get(k, "no usable result")
            statuses.append("fail")
            notes.append(f"shard {label}: no result ({why})")
            ci.append(entry("CI", "", 0, f"no-result:mutants:{k}", "env", "fail",
                            f"mutants shard {label} produced no result: {why}",
                            "see the job log; the mutants of this shard did not run", "a merged result without that shard"))
            continue
        c = env["checks"]["R3"]
        statuses.append(c["status"])
        notes.append(f"shard {label}: {c['note']}")
        kept += [e for e in env["entries"] if e["check"] == "R3"]
        if c.get("tested") is not None:
            counted = True
            tested += c["tested"]
            if c.get("total") is None:
                unknown = True
            else:
                total += c["total"]
    if "fail" in statuses:
        status = "fail"
    elif "n/a" in statuses:
        status = "n/a"
    elif "partial" in statuses:
        status = "partial"
    elif statuses and all(s == "skipped" for s in statuses):
        status = "skipped"
    else:
        status = "pass"
    check = {"status": status, "note": "; ".join(notes)}
    if counted:
        check["tested"] = tested
        check["total"] = None if unknown else total
    checks["R3"] = check
    ci = finalize(ci)
    entries = sorted(kept + ci, key=lambda e: (e["file"], e["line"] == 0, e["line"], e["id"]))
    return envelope(base, head, entries, checks)
