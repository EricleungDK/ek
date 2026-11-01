"""R3 mutation on the diff: cargo-mutants (pinned) runs on the changed production code; the verdict comes from its output files.

Contract used (cargo-mutants 27.1.0, read from its source and checked on real runs; see docs/mech-review-ci.md):
  exit: 0 nothing missed (or no mutants in the diff: no output dir), 2 MISSED, 3 TIMEOUT (wins over 2),
        4 unmutated baseline fails, 1/5/6/70 usage, diff or internal error.
  <out>/mutants.out/mutants.json   every mutant of this run (written before the baseline runs).
  <out>/mutants.out/outcomes.json  {outcomes: [{scenario: "Baseline" | {"Mutant": {...}}, summary}], total_mutants, ...},
                                   rewritten after each scenario, so a run killed by a budget keeps what it finished.
Summary per mutant: MissedMutant, CaughtMutant, Timeout, Unviable, Success (baseline).

Verdict (per shard):
  MISSED in a production file -> fail entry per mutant (class agent-fixable). TIMEOUT and UNVIABLE are ignored.
  budget hit: partial `tested/total` when no MISSED so far; fail when a MISSED was found.
  tool not runnable or an unexpected exit -> n/a (env), never pass.
  no mutants in the diff -> pass.
"""
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import tempfile

from . import red
from .engine import entry, finalize, git

DEFAULT_CMD = "cargo mutants"
MUTANT_TIMEOUT = 120  # seconds per cargo command (cargo-mutants --timeout): a mutant whose tests hang is a TIMEOUT
PROBE_TIMEOUT = 120  # seconds for `cargo mutants --version`

RE_POS = re.compile(r"^[^\s:]+:\d+:\d+: ")  # "src/lib.rs:2:11: replace + with - in add" -> "replace + with - in add"


def _load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _first_line(text):
    for line in (text or "").splitlines():
        if line.strip():
            return line.strip()[:200]
    return ""


def _check(status, note, tested=None, total=None):
    c = {"status": status, "note": note}
    if tested is not None:
        c["tested"] = tested
        c["total"] = total
    return c


def _mutant_outcomes(doc):
    """[(summary, mutant dict)] for each mutant scenario in outcomes.json (the baseline is not a mutant)."""
    out = []
    for oc in (doc or {}).get("outcomes", []):
        sc = oc.get("scenario")
        if isinstance(sc, dict) and "Mutant" in sc:
            out.append((oc.get("summary"), sc["Mutant"]))
    return out


def _desc(name):
    """mutant description without its file:line:col prefix: stable across line moves."""
    return RE_POS.sub("", name or "", count=1)


def verdict(mo, rc, text, adapter, test_globs):
    """R3 verdict of one run. mo: the mutants.out directory (cargo-mutants -o DIR writes DIR/mutants.out).
    rc: the exit code, "timeout" (budget killed the run), or None (tool not runnable). text: its output.
    Returns (check, entries): check is {status, note[, tested, total]}, entries are finalized contract entries."""
    if rc is None:
        return _check("n/a", f"cargo-mutants not runnable (env): {_first_line(text)}"), []
    mutants = _load(os.path.join(mo, "mutants.json"))
    total = len(mutants) if isinstance(mutants, list) else None
    doc = _load(os.path.join(mo, "outcomes.json"))
    rows = _mutant_outcomes(doc)
    tested = len(rows)
    counts = {k: sum(1 for s, _ in rows if s == k) for k in ("MissedMutant", "CaughtMutant", "Timeout", "Unviable")}
    entries = []
    for summary, m in rows:
        if summary != "MissedMutant" or adapter.classify(m.get("file", ""), test_globs) != "prod":
            continue
        name, file = m.get("name", ""), m.get("file", "")
        desc = _desc(name)
        entries.append(entry("R3", file, m.get("span", {}).get("start", {}).get("line", 0), f"missed:{file}|{desc}",
                             "agent-fixable", "fail", f"MISSED mutant {name}",
                             f"add an assert that fails for this mutant: {desc}",
                             f"MISSED mutant `{desc}` in `{file}`"))
    entries = finalize(entries)
    missed = counts["MissedMutant"]

    if rc == "timeout":
        shown = f"{tested}/{total if total is not None else '?'}"
        if missed:
            return _check("fail", f"{shown} tested: budget hit, {missed} missed", tested, total), entries
        return _check("partial", f"{shown} tested: budget hit, no MISSED so far", tested, total), []
    if rc == 4:
        return _check("fail", "baseline tests fail at head: mutants not run"), [
            entry("R3", "", 0, "baseline", "agent-fixable", "fail", "baseline tests fail at head: mutants not run",
                  "fix the failing tests first: mutation needs an unmutated tree that passes",
                  "a mutation check that did not run")]
    if rc in (0, 2, 3):
        if doc is None:
            if rc == 0 and not total:
                return _check("pass", "0 mutants in the diff", 0, 0), []
            return _check("n/a", f"cargo-mutants wrote no outcomes (env), exit {rc}"), []
        status = "fail" if entries else "pass"
        note = (f"{tested}/{total if total is not None else tested} tested: {missed} missed, "
                f"{counts['CaughtMutant']} caught, {counts['Timeout']} timeout, {counts['Unviable']} unviable")
        return _check(status, note, tested, total), entries
    return _check("n/a", f"cargo-mutants exit {rc} (env): {_first_line(text)}"), []


def _kill_group(proc):
    """cargo-mutants starts cargo test in its own children: the whole process group goes."""
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except OSError:
        proc.kill()


def default_runner():
    """Real runner: (argv, cwd, budget seconds or None) -> (rc, output); rc None when the executable is missing,
    "timeout" when the budget killed the run. MECH_TEST_STUB, when set, replaces argv[0] (the stub, like the R1/R4 runner)."""
    stub = os.environ.get("MECH_TEST_STUB")

    def run(argv, cwd, budget):
        if stub:
            argv = [stub] + argv[1:]
        try:
            proc = subprocess.Popen(argv, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    start_new_session=True)
        except OSError:
            return None, f"{argv[0]}: not found"
        try:
            out, _ = proc.communicate(timeout=budget)
        except subprocess.TimeoutExpired:
            _kill_group(proc)
            out, _ = proc.communicate()
            return "timeout", (out or b"").decode("utf-8", "replace")
        return proc.returncode, out.decode("utf-8", "replace")

    return run


def run(repo, mb, head, adapter, test_globs, cmd=DEFAULT_CMD, budget_min=None, shard=None,
        mutant_timeout=MUTANT_TIMEOUT, runner=None):
    """R3 for mb..head. Returns (check, entries). Skipped without a production change; n/a without the tool.
    cargo-mutants runs in a worktree at head (the caller's checkout does not move), on the diff only."""
    runner = runner or default_runner()
    if not red.prod_changes(repo, mb, head, adapter, test_globs):
        return _check("skipped", "no production file changed"), []
    rc, text = runner(shlex.split(cmd) + ["--version"], repo, PROBE_TIMEOUT)
    if rc != 0 or not text.startswith("cargo-mutants"):
        return _check("n/a", f"cargo-mutants not installed (env): {_first_line(text)}"), []
    budget = None if budget_min is None else budget_min * 60
    tmp = tempfile.mkdtemp(prefix="mech-mutants-")
    try:
        diff_path = os.path.join(tmp, "in.diff")
        with open(diff_path, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.write(git(repo, "diff", "--no-ext-diff", "--no-textconv", "-U0", "--src-prefix=a/", "--dst-prefix=b/",
                        mb, head))
        out_parent = os.path.join(tmp, "out")
        argv = shlex.split(cmd) + ["--in-diff", diff_path, "--timeout", str(mutant_timeout), "--colors", "never",
                                   "--output", out_parent]
        if shard:
            argv += ["--shard", shard]
        with red.worktree(repo, head) as wt:
            rc, text = runner(argv, wt, budget)
        return verdict(os.path.join(out_parent, "mutants.out"), rc, text, adapter, test_globs)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
