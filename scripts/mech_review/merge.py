"""Merge the job results (r2 guard, red red-first) into one envelope for the sticky comment.

Each job owns its checks: r2 owns R2, red owns R1 and R4. A job with no usable result (missing, unreadable,
or for another head) fails the checks it owns and adds one CI entry naming it, so a crash in one job never
hides the other job's entries.
"""
from .engine import CHECKS, entry, envelope, finalize

OWNS = {"r2": ("R2",), "red": ("R1", "R4")}


def merge(parts, reasons):
    """parts: {job: envelope or None}, reasons: {job: why it has no envelope}. At least one envelope is present."""
    present = [env for env in parts.values() if env is not None]
    if not present:
        raise ValueError("merge needs at least one envelope")
    first = present[0]
    checks = {c: {"status": "skipped", "note": "not implemented"} for c in CHECKS}
    checks["R3"] = first["checks"].get("R3", checks["R3"])  # mutation: no job runs it yet
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
