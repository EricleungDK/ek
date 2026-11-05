"""Mechanical review engine: runs the checks a subcommand asks for and builds the contract envelope."""
from . import mutants, red
from .gitio import Review, merge_base
from .r2 import r2
from .report import CHECKS, envelope, finalize
from .stack import ADAPTERS


def plan(repo, base_ref, head_ref, stack, test_globs, shards):
    """Mutants job plan (git only, no toolchain): run only when a production file changed. The matrix is
    shards 0..N-1 when it runs, one placeholder shard otherwise (the job is skipped by its `if`). The workflow reads
    only `run`: the real shard count is the baseline step's (#46)."""
    base, head, mb = merge_base(repo, base_ref, head_ref)
    run_r3 = bool(red.prod_changes(Review(repo, mb, head, ADAPTERS[stack](), test_globs)))
    count = shards if run_r3 else 1
    return {"run": run_r3, "count": count, "shards": list(range(count))}


def baseline(repo, base_ref, head_ref, stack, test_globs, mutants_cmd=None, mutation_budget=None, shards=4, project_dir="."):
    """The baseline step (#46): the mutants job's plan and its one baseline run. Envelope with the R3 check and the
    run decision: run, count (shards), mutants, timeout (the derived per-mutant seconds). Git only for the file-sharded
    stacks; rust runs cargo-mutants' unmutated baseline once."""
    base, head, mb = merge_base(repo, base_ref, head_ref)
    p = mutants.baseline(Review(repo, mb, head, ADAPTERS[stack](), test_globs, project_dir), mutants_cmd, mutation_budget,
                         shards)
    checks = {c: {"status": "skipped", "note": "not run by baseline"} for c in CHECKS}
    checks["R3"] = p["check"]
    env = envelope(base, head, p["entries"], checks)
    env.update({"run": p["run"], "count": p["count"], "mutants": p["mutants"], "timeout": p["timeout"]})
    return env


# which checks each subcommand runs; the rest are reported skipped with the subcommand named
WHICH = {"r2": ("R2",), "red": ("R1", "R4"), "all": ("R1", "R2", "R4"), "mutants": ("R3",)}


def run(repo, base_ref, head_ref, stack, test_globs, protected_globs=(), which="r2", agent_prefix="agent/",
        head_branch=None, test_cmd=None, runner=None, mutants_cmd=None, mutation_budget=None, shard=None,
        mutant_timeout=None, mutant_runner=None, project_dir="."):
    base, head, mb = merge_base(repo, base_ref, head_ref)
    rv = Review(repo, mb, head, ADAPTERS[stack](), test_globs, project_dir)
    want = WHICH[which]
    checks = {c: {"status": "skipped", "note": f"not run by {which}"} for c in CHECKS}
    raw = []
    if "R2" in want:
        raw += r2(rv, list(protected_globs))
        fails = sum(1 for e in raw if e["severity"] == "fail")
        checks["R2"] = {"status": "fail" if fails else "pass", "note": f"{fails} fail, {len(raw) - fails} confirm"}
    else:
        checks["R2"] = {"status": "skipped", "note": f"not run by {which}"}
    if "R1" in want or "R4" in want:
        cmd = test_cmd  # None: each checkout resolves its stack's command (red.r1/r4)
        run_test = runner or red.default_runner()
    if "R1" in want:
        checks["R1"], more = red.r1(rv, head_branch, agent_prefix, cmd, run_test)
        raw += more
    else:
        checks["R1"] = {"status": "skipped", "note": f"not run by {which}"}
    if "R4" in want:
        checks["R4"], more = red.r4(rv, cmd, run_test)
        raw += more
    else:
        checks["R4"] = {"status": "skipped", "note": f"not run by {which}"}
    if which == "all":
        checks["R3"] = {"status": "skipped", "note": "not run by all: R3 runs only in the mutants subcommand (CI job mutants)"}
    r3 = []
    if "R3" in want:
        checks["R3"], r3 = mutants.run(rv, mutants_cmd, mutation_budget, shard, mutant_timeout, mutant_runner)
    entries = sorted(finalize(raw) + r3, key=lambda e: (e["file"], e["line"] == 0, e["line"], e["id"]))
    return envelope(base, head, entries, checks)
