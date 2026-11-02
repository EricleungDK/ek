"""Merge the job results into one envelope for the sticky comment, and the mutants shards into the mutants job result.

Each job owns its checks: r2 owns R2, red owns R1 and R4, mutants owns R3. A job with no usable result (missing,
unreadable, or for another head) fails the checks it owns and adds one CI entry naming it, so a crash in one job
never hides the other job's entries. A job that was not run (no production file changed) is simply absent: its
checks stay skipped.
"""
import hashlib
import json

from .engine import CHECKS, entry, envelope, finalize
from .mutants import partial_entry

OWNS = {"r2": ("R2",), "red": ("R1", "R4"), "mutants": ("R3",)}


def merge(parts, reasons):
    """parts: {job: envelope or None}, reasons: {job: why it has no envelope}. At least one envelope is present."""
    present = [env for env in parts.values() if env is not None]
    if not present:
        raise ValueError("merge needs at least one envelope")
    first = present[0]
    checks = {c: {"status": "skipped", "note": "not run by any job"} for c in CHECKS}
    checks["R3"] = {"status": "skipped", "note": "not run: no production file changed"}
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


MUT_SUMS = ("mutant_build_s", "mutant_test_s")  # summed over the shards
BASE_KEYS = ("baseline_build_s", "baseline_test_s")  # measured once, by the baseline step (#46)


def _num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def combine_timing(items, tested, baseline_timing=None):
    """Timing of the merged R3. items: [(shard label, timing dict or None, shard tested or None)] for every shard.
    Mutant build and test sums and the average are kept when every shard reported them. A shard that tested nothing
    counts as zero for the sums (it has no mutant time to report). A crashed shard (no timing, tested unknown) drops them,
    so a missing shard never shrinks a total silently. Baseline seconds come once, from the baseline step, never summed
    over the shards. Wall is the slowest shard (they run in parallel); per-shard wall is kept; top five slowest."""
    reported = [(lab, t, n) for lab, t, n in items if t or n == 0]
    out = {}
    if reported and len(reported) == len(items):
        for key in MUT_SUMS:
            vals = [(t or {}).get(key, 0.0 if n == 0 else None) for _, t, n in reported]
            if all(_num(v) for v in vals):
                out[key] = round(sum(vals), 2)
        walls = [(t or {}).get("wall_s") for _, t, _ in reported]
        if all(_num(w) for w in walls):
            out["wall_s"] = max(walls)
        if "mutant_build_s" in out and "mutant_test_s" in out and tested:
            out["avg_s_per_mutant"] = round((out["mutant_build_s"] + out["mutant_test_s"]) / tested, 2)
    for key in BASE_KEYS:
        if baseline_timing and _num(baseline_timing.get(key)):
            out[key] = round(baseline_timing[key], 2)
    if not reported:
        return out
    out["shards"] = [{"shard": lab, "wall_s": t["wall_s"]} for lab, t, _ in reported if t and "wall_s" in t]
    per = [x for _, t, _ in reported if t for x in t.get("slowest", [])]
    if per:
        out["slowest"] = sorted(per, key=lambda x: -x["s"])[:5]
    return out


def _add_unique(kept, seen, e, label):
    """One entry per id across shards. An exact repeat (same id, same content) collapses. A different entry that shares
    an id (two mutants with one description in one file, split across shards) gets a new id derived from its own id and
    its shard, so neither is lost: a fail must not vanish in a merge."""
    cur = seen.get(e["id"])
    if cur is None:
        seen[e["id"]] = e
        kept.append(e)
        return
    if cur == e:
        return
    n = 0
    while True:
        n += 1
        new = f"{e['check']}-" + hashlib.sha1(f"{e['id']}|{label}|{n}".encode("utf-8")).hexdigest()[:8]
        if new not in seen:
            break
    e = dict(e, id=new)
    seen[new] = e
    kept.append(e)


def combine_shards(base, head, n, shards, reasons, baseline_timing=None):
    """The mutants job: R3 from n shard envelopes (0-based shard k of n). shards: {k: envelope or None},
    reasons: {k: why there is no envelope}. A missing shard fails R3 with a CI entry naming it; the other shards'
    entries stay. R3 status: fail > n/a > partial > skipped > pass; tested/total are summed over the shards.
    Partial: exactly one partial confirm for the merged run, however many shards hit the budget.
    Entries: one per id (see _add_unique)."""
    checks = {c: {"status": "skipped", "note": "not run by mutants"} for c in CHECKS}
    kept, ci, notes, statuses, timings = [], [], [], [], []
    seen = {}
    tested = total = 0
    counted = unknown = False
    guard_id = partial_entry({})["id"]
    for k in range(n):
        label = f"{k}/{n}"
        env = shards.get(k)
        if env is None:
            why = reasons.get(k, "no usable result")
            statuses.append("fail")
            notes.append(f"shard {label}: no result ({why})")
            timings.append((label, None, None))
            ci.append(entry("CI", "", 0, f"no-result:mutants:{k}", "env", "fail",
                            f"mutants shard {label} produced no result: {why}",
                            "see the job log; the mutants of this shard did not run", "a merged result without that shard"))
            continue
        c = env["checks"]["R3"]
        statuses.append(c["status"])
        notes.append(f"shard {label}: {c['note']}")
        timings.append((label, c.get("timing"), c.get("tested")))
        # a shard's own partial confirm is replaced by the one for the merged run
        for e in env["entries"]:
            if e["check"] == "R3" and e["id"] != guard_id:
                _add_unique(kept, seen, e, label)
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
    timing = combine_timing(timings, tested if counted else None, baseline_timing)
    if timing:
        check["timing"] = timing
    checks["R3"] = check
    if status == "partial":
        kept.append(partial_entry(check))
    ci = finalize(ci)
    entries = sorted(kept + ci, key=lambda e: (e["file"], e["line"] == 0, e["line"], e["id"]))
    return envelope(base, head, entries, checks)


def combine_mutants(base, head, n, shards, reasons, baseline=None, baseline_reason=None):
    """The R3 result of the mutants job (#46). baseline: the baseline step's envelope (checks.R3, run, entries), or None when
    that job produced no result (baseline_reason says why): then R3 fails with one CI entry naming it. Neither given: the
    shards merge alone. A baseline that did not run the shards is the R3 result (fail, n/a, or pass with no mutant).
    Otherwise the shards merge, and the baseline's timing (its seconds, once) is added."""
    if baseline is None and baseline_reason is None:
        return combine_shards(base, head, n, shards, reasons)  # shards only: no baseline step was given
    if baseline is None:
        why = baseline_reason
        checks = {c: {"status": "skipped", "note": "not run by mutants"} for c in CHECKS}
        checks["R3"] = {"status": "fail", "note": f"no result from baseline job: {why}"}
        ci = [entry("CI", "", 0, "no-result:baseline", "env", "fail", f"baseline job produced no result: {why}",
                    "see the job log; the mutants shards did not run", "a merged result without the baseline step")]
        return envelope(base, head, finalize(ci), checks)
    if not baseline.get("run"):
        checks = {c: {"status": "skipped", "note": "not run by mutants"} for c in CHECKS}
        checks["R3"] = baseline["checks"]["R3"]
        ents = [e for e in baseline.get("entries", []) if e.get("check") == "R3"]
        return envelope(base, head, sorted(ents, key=lambda e: (e["file"], e["line"] == 0, e["line"], e["id"])), checks)
    timing = (baseline["checks"]["R3"].get("timing") or {}) if isinstance(baseline.get("checks"), dict) else {}
    return combine_shards(base, head, n, shards, reasons, baseline_timing=timing)
