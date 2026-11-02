"""R3 mutation on the diff. One tool per stack: cargo-mutants (rust, pinned) runs `--in-diff` and reads its output files;
mutmut (python, pinned) runs on the changed files and reads its results through `mutmut results` and `mutmut show`.
Both run in the crate dir (project-dir). The shared parts (budget runner, verdict shape, partial entry, timing) live here.

cargo-mutants contract:

Contract used (cargo-mutants 27.1.0, read from its source and checked on real runs; see docs/mech-review-ci.md):
  exit: 0 nothing missed (or no mutants in the diff: no output dir), 2 MISSED, 3 TIMEOUT (wins over 2),
        4 unmutated baseline fails, 1/5/6/70 usage, diff or internal error.
  <out>/mutants.out/mutants.json   every mutant of this run (written before the baseline runs).
  <out>/mutants.out/outcomes.json  {outcomes: [{scenario: "Baseline" | {"Mutant": {...}}, summary}], total_mutants, ...},
                                   rewritten after each scenario, so a run killed by a budget keeps what it finished.
Summary per mutant: MissedMutant, CaughtMutant, Timeout, Unviable, Success (baseline).

Verdict (per shard):
  MISSED in a production file -> fail entry per mutant (class agent-fixable). TIMEOUT and UNVIABLE are ignored.
  budget hit: partial `tested/total` when no MISSED so far; fail when a MISSED was found. A budget hit before the
  baseline finished: partial 0 tested, the note says the baseline did not finish.
  baseline Timeout (exit 4, outcomes Baseline summary Timeout): n/a, never a fail. Only an explicit --timeout limits the
  baseline (cargo-mutants 27.1.0), so the note names mutant-timeout. baseline Failure: fail (agent-fixable).
  tool not runnable or an unexpected exit -> n/a (env), never pass.
  no mutants in the diff -> pass.
"""
import json
import os
import posixpath
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

from . import red
from .engine import added_lines, entry, finalize, git
from .stack import ts_runner

DEFAULT_CMD = "cargo mutants"
PROBE_TIMEOUT = 120  # seconds for `cargo mutants --version`
KILL_GRACE = 15  # seconds between SIGTERM and SIGKILL when a run is over its budget
REAP = 5  # seconds to wait for a killed run before giving up on it

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
    """[(summary, mutant dict, phase_results)] for each mutant scenario in outcomes.json (the baseline is not a mutant)."""
    out = []
    for oc in (doc or {}).get("outcomes", []):
        if not isinstance(oc, dict):
            continue
        sc = oc.get("scenario")
        if isinstance(sc, dict) and "Mutant" in sc:
            out.append((oc.get("summary"), sc["Mutant"], oc.get("phase_results")))
    return out


def _baseline(doc):
    """the Baseline scenario's outcome dict in outcomes.json, or None (not written yet: the run was killed before it ended)."""
    return next((oc for oc in (doc or {}).get("outcomes", [])
                 if isinstance(oc, dict) and oc.get("scenario") == "Baseline"), None)


def _desc(name):
    """mutant description without its file:line:col prefix: stable across line moves."""
    return RE_POS.sub("", name or "", count=1)


def _secs(x):
    """seconds as a float, or None when the value is not a usable duration."""
    if isinstance(x, bool) or not isinstance(x, (int, float)) or x != x or x < 0:
        return None
    return float(x)


def _phase(phases, name, absent=0.0):
    """Seconds spent in one phase. A phase that is not there is `absent` (cargo-mutants stops after a failed build,
    so an unviable mutant has no Test); a phase that is there with an unusable duration is None (field left out)."""
    if not isinstance(phases, list):
        return None
    found = [p for p in phases if isinstance(p, dict) and p.get("phase") == name]
    if not found:
        return absent
    vals = [_secs(p.get("duration")) for p in found]
    if any(v is None for v in vals):
        return None
    return sum(vals)


def _timing(doc, rows, wall_s):
    """Per-shard timing from the run's own phase durations: wall (the runner's clock), baseline build and test, summed
    mutant build and test, average per tested mutant, the five slowest mutants. Any field that cannot be read is left out."""
    t = {}
    if wall_s is not None:
        t["wall_s"] = round(float(wall_s), 2)
    base = _baseline(doc)
    if base:
        for key, phase in (("baseline_build_s", "Build"), ("baseline_test_s", "Test")):
            v = _phase(base.get("phase_results"), phase, absent=None)
            if v is not None:
                t[key] = round(v, 2)
    mb = mt = 0.0
    b_ok = t_ok = True
    per = []
    for _, m, phases in rows:
        b, tt = _phase(phases, "Build"), _phase(phases, "Test")
        if b is None:
            b_ok = False
        else:
            mb += b
        if tt is None:
            t_ok = False
        else:
            mt += tt
        if b is not None and tt is not None:
            per.append({"name": str(m.get("name", "")), "s": round(b + tt, 2)})
    if rows and b_ok:
        t["mutant_build_s"] = round(mb, 2)
    if rows and t_ok:
        t["mutant_test_s"] = round(mt, 2)
    if rows and b_ok and t_ok:
        t["avg_s_per_mutant"] = round((mb + mt) / len(rows), 2)
    if per:
        t["slowest"] = sorted(per, key=lambda x: -x["s"])[:5]
    return t


PARTIAL_KEY = "partial"


def partial_entry(check):
    """The one confirm entry for a partial R3 (agent-fixable): its id is stable across heads and counts, the text names
    the untested mutants (or says the total is unknown)."""
    tested, total = check.get("tested"), check.get("total")
    if total is None:
        problem = (f"R3 partial: total unknown ({tested if tested is not None else '?'} tested): "
                   "untested mutants unknown at budget")
    elif tested is None:
        problem = f"R3 partial: {total} mutants, tested count unknown at budget"
    else:
        problem = f"R3 partial: {total - tested}/{total} mutants untested at budget"
    e = entry("R3", "", 0, PARTIAL_KEY, "agent-fixable", "confirm", problem,
              "read checks.R3.timing (wall, phase seconds, slowest mutants): shrink the diff first, then narrow the tests "
              "cargo-mutants runs, then raise mutation-budget",
              "treating a partial R3 as tested")
    return finalize([e])[0]


def _repo_path(project_dir, path):
    """cargo-mutants names files relative to the crate dir; the result names them relative to the repo root."""
    return path if project_dir == "." else posixpath.join(project_dir, path)


def _baseline_timeout_note(timeout_s):
    """n/a note for a baseline cargo-mutants timed out: names the timeout, its seconds and the two inputs that set it."""
    after = f" after {timeout_s:g}s" if timeout_s is not None else ""
    return (f"baseline tests timed out{after} (mutant-timeout caps the baseline too): mutants not run; raise mutant-timeout "
            "above the suite time (auto leaves the baseline unlimited); mutation-budget does not lift it")


def verdict(mo, rc, text, adapter, test_globs, wall_s=None, project_dir=".", timeout_s=None):
    """R3 verdict of one run. mo: the mutants.out directory (cargo-mutants -o DIR writes DIR/mutants.out).
    rc: the exit code, "timeout" (budget killed the run), or None (tool not runnable). text: its output.
    wall_s: the runner's clock for this run, if measured. project_dir: the crate dir under the repo root.
    timeout_s: the --timeout (seconds) the run was given, or None (auto): named in a baseline timeout's note.
    Returns (check, entries): check is {status, note[, tested, total, timing]}, entries are finalized contract entries."""
    if rc is None:
        return _check("n/a", f"cargo-mutants not runnable (env): {_first_line(text)}; check the cargo-mutants install step"), []
    mutants = _load(os.path.join(mo, "mutants.json"))
    total = len(mutants) if isinstance(mutants, list) else None
    doc = _load(os.path.join(mo, "outcomes.json"))
    rows = _mutant_outcomes(doc)
    tested = len(rows)
    counts = {k: sum(1 for s, _, _ in rows if s == k) for k in ("MissedMutant", "CaughtMutant", "Timeout", "Unviable")}
    entries = []
    for summary, m, _ in rows:
        raw = m.get("file", "")
        file = _repo_path(project_dir, raw)
        if summary != "MissedMutant" or adapter.classify(file, test_globs) != "prod":
            continue
        name = m.get("name", "")
        if name.startswith(raw + ":"):
            name = file + name[len(raw):]
        desc = _desc(name)
        entries.append(entry("R3", file, m.get("span", {}).get("start", {}).get("line", 0), f"missed:{file}|{desc}",
                             "agent-fixable", "fail", f"MISSED mutant {name}",
                             f"add an assert that fails for this mutant: {desc}",
                             f"MISSED mutant `{desc}` in `{file}`"))
    entries = finalize(entries)
    missed = counts["MissedMutant"]
    timing = _timing(doc, rows, wall_s)

    def done(check, ents):
        if timing:
            check["timing"] = timing
        return check, ents

    base = _baseline(doc)
    if rc == "timeout":
        shown = f"{tested}/{total if total is not None else '?'}"
        if base is None:  # killed before the baseline ended: no mutant ran
            return done(_check("partial", f"{shown} tested: budget hit, baseline did not finish: no mutant run", 0, total),
                        [])
        if missed:
            return done(_check("fail", f"{shown} tested: budget hit, {missed} missed", tested, total), entries)
        return done(_check("partial", f"{shown} tested: budget hit, no MISSED so far", tested, total), [])
    if rc == 4 and base is not None and base.get("summary") == "Timeout":
        return done(_check("n/a", _baseline_timeout_note(timeout_s)), [])
    if rc == 4:
        return done(_check("fail", "baseline tests fail at head: mutants not run"), [
            finalize([entry("R3", "", 0, "baseline", "agent-fixable", "fail", "baseline tests fail at head: mutants not run",
                            "fix the failing tests first: mutation needs an unmutated tree that passes",
                            "a mutation check that did not run")])[0]])
    if rc in (0, 2, 3):
        if doc is None:
            if rc == 0 and not total:
                return done(_check("pass", "0 mutants in the diff", 0, 0), [])
            return _check("n/a", f"cargo-mutants wrote no outcomes (env), exit {rc}; see the job log"), []
        status = "fail" if entries else "pass"
        note = (f"{tested}/{total if total is not None else tested} tested: {missed} missed, "
                f"{counts['CaughtMutant']} caught, {counts['Timeout']} timeout, {counts['Unviable']} unviable")
        return done(_check(status, note, tested, total), entries)
    return _check("n/a", f"cargo-mutants exit {rc} (env): {_first_line(text) or 'no output'}; see the job log"), []


def _signal_run(proc, sig):
    """Signal the run's process group (cargo-mutants and what did not leave it), then the process itself."""
    try:
        os.killpg(proc.pid, sig)
    except OSError:
        pass
    try:
        proc.send_signal(sig)
    except OSError:
        pass


def _stop(proc):
    """Over budget: SIGTERM first so cargo-mutants can stop its children (it puts cargo test in its own group, which
    a group signal does not reach); SIGKILL after KILL_GRACE; the wait for the killed process is bounded too."""
    _signal_run(proc, signal.SIGTERM)
    try:
        proc.wait(timeout=KILL_GRACE)
    except subprocess.TimeoutExpired:
        _signal_run(proc, signal.SIGKILL)
        try:
            proc.wait(timeout=REAP)
        except subprocess.TimeoutExpired:
            pass  # a child that escaped the group may outlive it; the runner still returns


def default_runner():
    """Real runner: (argv, cwd, budget seconds or None) -> (rc, output); rc None when the executable is missing,
    "timeout" when the budget stopped the run. Output goes to a file, not a pipe, so no child holding it can block
    the runner. MECH_TEST_STUB, when set, replaces argv[0] (the stub, like the R1/R4 runner)."""
    stub = os.environ.get("MECH_TEST_STUB")

    def run(argv, cwd, budget):
        if stub:
            argv = [stub] + argv[1:]
        with tempfile.TemporaryFile() as out:
            try:
                proc = subprocess.Popen(argv, cwd=cwd, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
            except OSError:
                return None, f"{argv[0]}: not found"
            try:
                proc.wait(timeout=budget)
                rc = proc.returncode
            except subprocess.TimeoutExpired:
                _stop(proc)
                rc = "timeout"
            out.seek(0)
            return rc, out.read().decode("utf-8", "replace")

    return run


DIAG_LINES = 40  # lines of cargo-mutants' own log printed to stderr on a non-pass R3


def _diagnose(mo, text, status):
    """A non-pass R3: the last DIAG_LINES of cargo-mutants' log/baseline.log (its output when no log was written) to
    stderr, so the job log shows why. stdout stays the JSON contract."""
    try:
        with open(os.path.join(mo, "log", "baseline.log"), encoding="utf-8", errors="replace") as f:
            lines, src = f.read().splitlines(), "log/baseline.log"
    except OSError:
        lines, src = (text or "").splitlines(), "output"
    tail = lines[-DIAG_LINES:]
    print(f"mech-review: R3 {status}: last {len(tail)} lines of cargo-mutants {src}", file=sys.stderr)
    for line in tail:
        print(line, file=sys.stderr)


class CargoMutants:
    """R3 for rust: cargo-mutants --in-diff in the crate dir of a worktree at head; verdict from its output files.
    mutant_timeout None (auto) sends no --timeout: cargo-mutants sets the per-mutant limit from the baseline, and the
    baseline runs unlimited. A number sends --timeout N, which also caps the baseline (cargo-mutants 27.1.0)."""
    default_cmd = DEFAULT_CMD

    def check(self, repo, mb, head, adapter, test_globs, cmd, budget_min, shard, mutant_timeout, runner, project_dir="."):
        cmd = cmd or self.default_cmd
        rc, text = runner(shlex.split(cmd) + ["--version"], repo, PROBE_TIMEOUT)
        if rc != 0 or not text.startswith("cargo-mutants"):
            return _check("n/a", f"cargo-mutants not installed (env): `{cmd}` not runnable; check the cargo-mutants install step"), []
        budget = None if budget_min is None else budget_min * 60
        tmp = tempfile.mkdtemp(prefix="mech-mutants-")
        try:
            diff_path = os.path.join(tmp, "in.diff")
            relative = [] if project_dir == "." else [f"--relative={project_dir}"]
            with open(diff_path, "w", encoding="utf-8", errors="surrogateescape") as f:
                f.write(git(repo, "diff", "--no-ext-diff", "--no-textconv", "-U0", "--src-prefix=a/", "--dst-prefix=b/",
                            *relative, mb, head))
            out_parent = os.path.join(tmp, "out")
            limit = [] if mutant_timeout is None else ["--timeout", str(mutant_timeout)]
            argv = shlex.split(cmd) + ["--in-diff", diff_path] + limit + ["--colors", "never", "--output", out_parent]
            if shard:
                argv += ["--shard", shard]
            with red.worktree(repo, head) as wt:
                crate = os.path.join(wt, project_dir)
                if not os.path.isdir(crate):
                    return _check("fail", f"project dir {project_dir} not found at head: mutants not run"), [
                        finalize([entry("R3", "", 0, "project-dir", "agent-fixable", "fail",
                                        f"project dir {project_dir} not found at head: mutants not run",
                                        "set project-dir to the crate dir under the repo root, present at head",
                                        "a mutation check that did not run")])[0]]
                if not os.path.isfile(os.path.join(crate, "Cargo.toml")):
                    return _check("n/a", f"no Cargo.toml in {project_dir}: set project-dir"), []
                t0 = time.monotonic()
                rc, text = runner(argv, crate, budget)
                wall = time.monotonic() - t0
            mo = os.path.join(out_parent, "mutants.out")
            check, ents = verdict(mo, rc, text, adapter, test_globs, wall_s=wall, project_dir=project_dir,
                                  timeout_s=mutant_timeout)
            if check["status"] != "pass":
                _diagnose(mo, text, check["status"])
            return check, ents
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


MUTMUT_RESULT = re.compile(r"^ {4}(\S+): (.+?)\s*$", re.M)  # "    calc.core.x_add__mutmut_1: survived"
MUTMUT_SHOW_HEADER = re.compile(r"^--- (.+)$", re.M)  # "--- src/calc/core.py": the file of the mutated function


def parse_results(text):
    """[(mutant name, status)] from `mutmut results --all True`; noise lines (warnings, progress) are skipped."""
    return MUTMUT_RESULT.findall(text or "")


def parse_show(text):
    """(removed, added) of the first hunk of `mutmut show NAME` (whitespace-stripped), or None without a diff.
    The hunk covers the mutated function, so its line numbers are not the file's: see locate()."""
    removed, added, in_hunk = [], [], False
    for line in (text or "").splitlines():
        if line.startswith("@@"):
            in_hunk = True
        elif in_hunk and line.startswith("-"):
            removed.append(line[1:].strip())
        elif in_hunk and line.startswith("+"):
            added.append(line[1:].strip())
    if not removed and not added:
        return None
    return (" ".join(removed), " ".join(added))


def show_file(text):
    """the file a `mutmut show` diff is for (its `--- ` header), or None."""
    m = MUTMUT_SHOW_HEADER.search(text or "")
    return m.group(1).strip() if m else None


def mutant_scope(name):
    """(class chain, function) a mutmut name points at: `calc.core.x_add__mutmut_1` -> ([], "add");
    `calc.core.xǁCalcǁadd__mutmut_1` -> (["Calc"], "add") (mutmut joins the scope with U+01C1); None for any other form."""
    seg = name.rsplit(".", 1)[-1].split("__mutmut_")[0]
    if seg.startswith("x_"):
        return [], seg[2:]
    if seg.startswith("x") and "\u01c1" in seg:
        parts = seg[2:].split("\u01c1")  # "x" + separator + Class + separator + method
        return parts[:-1], parts[-1]
    return None


def _block_end(lines, start):
    """index after the block whose header is lines[start]: the first non-blank line at or left of its indent."""
    indent = len(lines[start]) - len(lines[start].lstrip())
    return next((j for j in range(start + 1, len(lines))
                 if lines[j].strip() and len(lines[j]) - len(lines[j].lstrip()) <= indent), len(lines))


def _find(lines, lo, hi, pattern):
    """first line index in [lo, hi) that the pattern matches at its start, or None."""
    rx = re.compile(pattern)
    return next((i for i in range(lo, hi) if rx.match(lines[i])), None)


def locate(src, name, removed):
    """1-based line of the removed text in the function a mutmut name points at, or None when the name cannot be
    mapped (no such class or function in the file, or a name form this does not read). A method is searched for
    inside its class, so the same method name in two classes resolves to the right one. Lines are the file's."""
    scope = mutant_scope(name)
    if scope is None:
        return None
    chain, fn = scope
    lines = (src or "").splitlines()
    lo, hi = 0, len(lines)
    for cls in chain:
        start = _find(lines, lo, hi, rf"\s*class\s+{re.escape(cls)}\b")
        if start is None:
            return None
        lo, hi = start + 1, _block_end(lines, start)
    if chain:
        start = _find(lines, lo, hi, rf"\s*(async\s+)?def\s+{re.escape(fn)}\s*\(")
    else:
        start = _find(lines, 0, len(lines), rf"(async\s+)?def\s+{re.escape(fn)}\s*\(")  # column 0: a module function
    if start is None:
        return None
    for j in range(start, _block_end(lines, start)):
        if lines[j].strip() == removed:
            return j + 1
    return None


def _glob_escape(path):
    """a literal path as an fnmatch pattern (mutmut matches only_mutate with fnmatch)."""
    return re.sub(r"([*?\[])", lambda m: f"[{m.group(1)}]", path)


def add_mutmut_table(text, sources, only):
    """pyproject text with a [tool.mutmut] table (source_paths, only_mutate) appended; None when the repo already
    configures mutmut (it is not overridden: only_mutate could not be set)."""
    text = text or ""
    if re.search(r"^\s*\[tool\.mutmut[\].]", text, re.M):
        return None
    block = "[tool.mutmut]\nsource_paths = %s\nonly_mutate = %s\n" % (
        json.dumps(sources), json.dumps([_glob_escape(p) for p in only]))
    return text + ("\n" if text.endswith("\n") else "\n\n" if text else "") + block


def shard_files(files, shard):
    """the changed production files of shard K/N (0-based, round robin over the sorted list); all when no shard."""
    if not shard:
        return list(files)
    k, n = (int(x) for x in shard.split("/"))
    return files[k::n]


def _kind(status, early):
    """what a mutmut status means for R3. Stopped early (no test covers any mutant): not checked is no tests."""
    if status == "not checked" and early:
        status = "no tests"
    if status in ("killed", "caught by type check"):
        return "caught"
    if status in ("survived", "no tests"):
        return "missed"
    if status == "not checked":
        return "untested"
    return "other"  # timeout, suspicious, skipped, segfault, interrupted: neither caught nor missed


def _write_config(wt, files):
    """the [tool.mutmut] table in the worktree's pyproject.toml (the caller's checkout is never written). False when
    the repo already configures mutmut."""
    path = os.path.join(wt, "pyproject.toml")
    text = None
    if os.path.exists(path):
        with open(path, encoding="utf-8", errors="surrogateescape") as f:
            text = f.read()
    sources = sorted({p.split("/", 1)[0] for p in files})
    new = add_mutmut_table(text, sources, files)
    if new is None:
        return False
    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(new)
    return True


def _under(path, project_dir):
    """the repo-root path is inside the crate dir (project-dir; `.` is the whole repo)."""
    return project_dir == "." or path == project_dir or path.startswith(project_dir + "/")


def _crate_path(project_dir, path):
    """repo-root path -> path under the crate dir (what mutmut names files by)."""
    return path if project_dir == "." else path[len(project_dir) + 1:]


class Mutmut:
    """R3 for python: mutmut 3.8.1 on the changed production files, in the crate dir of a worktree at head. mutmut has no
    line filter, so the MISSED list is narrowed to the changed lines afterwards (the same `--in-diff` promise as
    cargo-mutants). Paths in the result are repo-root paths. Timing: wall time only (mutmut keeps no per-phase durations
    in its output); the per-mutant timeout is mutmut's own (timeout_multiplier), so --mutant-timeout is not applied."""
    default_cmd = "mutmut"

    def check(self, repo, mb, head, adapter, test_globs, cmd, budget_min, shard, mutant_timeout, runner, project_dir="."):
        cmd = cmd or self.default_cmd
        prod = sorted({ch.new for ch in red.prod_changes(repo, mb, head, adapter, test_globs)
                       if ch.new and _under(ch.new, project_dir)})
        files = shard_files(prod, shard)
        changed = added_lines(repo, mb, head)
        budget = None if budget_min is None else budget_min * 60
        with red.worktree(repo, head) as wt:
            crate = os.path.join(wt, project_dir)
            if not os.path.isdir(crate):
                return _check("fail", f"project dir {project_dir} not found at head: mutants not run"), [
                    finalize([entry("R3", "", 0, "project-dir", "agent-fixable", "fail",
                                    f"project dir {project_dir} not found at head: mutants not run",
                                    "set project-dir to the crate dir under the repo root, present at head",
                                    "a mutation check that did not run")])[0]]
            if not any(os.path.isfile(os.path.join(crate, m)) for m in adapter.manifests):
                return _check("n/a", f"no {red.manifest_label(adapter)} in {project_dir}: set project-dir"), []
            if not files:
                return _check("pass", "0 mutants in the diff (no changed production file in this shard)", 0, 0), []
            if not _write_config(crate, [_crate_path(project_dir, f) for f in files]):
                return _check("n/a", f"the repo already configures mutmut ([tool.mutmut]) in {project_dir} (env): "
                                     "R3 cannot set only_mutate; not overridden"), []
            rc, text = runner(shlex.split(cmd) + ["--version"], crate, PROBE_TIMEOUT)
            if rc != 0 or not text.startswith("mutmut, version"):
                return _check("n/a", f"mutmut not installed (env): `{cmd}` not runnable; install mutmut 3.8.1 "
                                     "(python toolchain step) or set setup-command"), []
            t0 = time.monotonic()
            rc, text = runner(shlex.split(cmd) + ["run"], crate, budget)
            wall = time.monotonic() - t0
            early = "Stopping early" in text
            if rc == 1 and ("failed to collect stats" in text or "Failed to run clean test" in text):
                return _check("fail", "baseline tests fail at head: mutants not run"), finalize([
                    entry("R3", "", 0, "baseline", "agent-fixable", "fail", "baseline tests fail at head: mutants not run",
                          "fix the failing tests first: mutation needs an unmutated tree that passes",
                          "a mutation check that did not run")])
            if not (rc in ("timeout", 0) or (rc == 1 and early)):
                return _check("n/a", f"mutmut exit {rc} (env): {_first_line(text)}; check the test deps "
                                     "(requirements, setup-command)"), []
            rrc, rtext = runner(shlex.split(cmd) + ["results", "--all", "True"], crate, PROBE_TIMEOUT)
            if rrc != 0:
                return _check("n/a", f"mutmut results failed (env): {_first_line(rtext)}"), []
            rows = [(name, _kind(status, early), status) for name, status in parse_results(rtext)]
            tested = sum(1 for _, k, _ in rows if k != "untested")
            total = None if rc == "timeout" and not rows else len(rows)
            if rc != "timeout" and total == 0:
                return _check("pass", "0 mutants in the diff", 0, 0), []
            caught = sum(1 for _, k, _ in rows if k == "caught")
            found, outside, unlocated = [], 0, 0
            for name, k, status in rows:
                if k != "missed":
                    continue
                rc_s, show = runner(shlex.split(cmd) + ["show", name], crate, PROBE_TIMEOUT)
                parsed = parse_show(show) if rc_s == 0 else None
                if parsed is None:
                    unlocated += 1  # no diff to read: not a fail, not outside either; named by the confirm below
                    continue
                removed, after = parsed
                file = _repo_path(project_dir, show_file(show) or "")
                line = locate(_read(os.path.join(crate, _crate_path(project_dir, file))), name, removed)
                if line is None:
                    unlocated += 1  # the name maps to no line in the file: a confirm, never a silent fail
                    continue
                if line not in {n for n, _ in changed.get(file, [])}:
                    outside += 1
                    continue
                found.append((name, file, line, f"{removed} -> {after}", status))
            ents = finalize([
                entry("R3", file, line, f"missed:{file}|{desc}", "agent-fixable", "fail", f"MISSED mutant {file}:{line}: {desc}",
                      (f"add an assert that fails for this mutant: {desc}" if status == "survived" else
                       "no test reaches this line: add a test that calls it and asserts the result"),
                      f"MISSED mutant `{desc}` in `{file}`")
                for _, file, line, desc, status in found])
            if unlocated:
                ents += finalize([entry("R3", "", 0, "unlocated", "agent-fixable", "confirm",
                                        f"R3 unlocated: {unlocated} missed mutant(s) could not be mapped to a line: not blocking",
                                        "read checks.R3.note: the mutant's function is not in the file under the name mutmut uses; "
                                        "check its location by hand",
                                        "counting an unlocated mutant as outside the diff, or as a fail without a look")])
            shown = f"{tested}/{total if total is not None else '?'}"
            timing = {"wall_s": round(wall, 2)}
            fails = [e for e in ents if e["severity"] == "fail"]
            if rc == "timeout":
                if fails:
                    check = _check("fail", f"{shown} tested: budget hit, {len(fails)} missed", tested, total)
                else:
                    check = _check("partial", f"{shown} tested: budget hit, no MISSED so far", tested, total)
            else:
                note = (f"{shown} tested: {len(fails)} missed in the diff, {outside} missed outside the diff, "
                        f"{unlocated} unlocated, {caught} caught")
                check = _check("fail" if fails else "pass", note, tested, total)
            check["timing"] = timing
            return check, ents


def _read(path):
    try:
        with open(path, encoding="utf-8", errors="surrogateescape") as f:
            return f.read()
    except OSError:
        return ""


STRYKER_TIMEOUT = 120  # seconds: Stryker's per-mutant timeoutMS when --mutant-timeout is auto (as it was before auto)
STRYKER_REPORT = os.path.join("reports", "mutation", "mutation.json")  # Stryker's default JSON reporter file
STRYKER_INSTRUMENTED = re.compile(r"Instrumented \d+ source file\(s\) with (\d+) mutant")
STRYKER_BASELINE = "There were failed tests in the initial test run"
STRYKER_CONFIG_NAMES = tuple(f"{p}stryker{s}.{e}" for p in ("", ".") for s in (".conf", ".config")
                             for e in ("json", "js", "mjs", "cjs"))  # Stryker's own discovery order
STRYKER_VERSION = re.compile(r"^\d+\.\d+\.\d+$", re.M)
# vitest without a repo config: Stryker's command runner runs the suite per mutant (no per-test coverage). The vitest
# plugin of @stryker-mutator 10.0.0 completes no test for a test nested in describe on vitest 5 (verified), so it is not used.
VITEST_STRYKER_CONFIG = {"testRunner": "command", "commandRunner": {"command": "npx --no-install vitest run"},
                         "coverageAnalysis": "off", "checkers": [], "reporters": ["json"],
                         "thresholds": {"break": None}}


def _write_stryker_config(crate, config):
    """the temp config in the worktree's crate dir (the caller's checkout is never written; the repo has no config)."""
    with open(os.path.join(crate, "stryker.conf.json"), "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2)


def stryker_kind(status):
    """what a Stryker status means for R3. NoCoverage (no test reaches the mutant) is missed, as mutmut's no tests is."""
    if status == "Killed":
        return "caught"
    if status in ("Survived", "NoCoverage"):
        return "missed"
    return "other"  # Timeout, CompileError, RuntimeError, Ignored, Pending: neither caught nor missed


def stryker_total(log):
    """mutant count from Stryker's log line `Instrumented N source file(s) with M mutant(s)`, or None."""
    m = STRYKER_INSTRUMENTED.search(log or "")
    return int(m.group(1)) if m else None


def stryker_rows(doc):
    """[(crate-relative file, mutant dict, file source)] for every mutant of a Stryker JSON report. ValueError when the
    report's shape is not Stryker's (a file or a mutant that is not an object): a partial read would hide mutants."""
    files = (doc or {}).get("files") or {}
    if not isinstance(files, dict):
        raise ValueError("files is not an object")
    out = []
    for f, res in files.items():
        if not isinstance(res, dict) or not isinstance(res.get("mutants") or [], list):
            raise ValueError(f"{f} has no mutant list")
        for m in res.get("mutants") or []:
            if not isinstance(m, dict):
                raise ValueError(f"a mutant in {f} is not an object")
            out.append((f, m, res.get("source") or ""))
    return out


def _span_text(src, loc):
    """source text of a Stryker location (1-based lines and columns, end exclusive)."""
    lines = (src or "").split("\n")
    try:
        s, e = loc["start"], loc["end"]
        if s["line"] == e["line"]:
            return lines[s["line"] - 1][s["column"] - 1:e["column"] - 1]
        mid = lines[s["line"]:e["line"] - 1]
        return "\n".join([lines[s["line"] - 1][s["column"] - 1:]] + mid + [lines[e["line"] - 1][:e["column"] - 1]])
    except (KeyError, IndexError, TypeError):
        return ""


def stryker_desc(m, src):
    """`Mutator `original` -> `replacement``: stable across line moves (no line or column in it)."""
    orig = " ".join(_span_text(src, m.get("location") or {}).split())
    if len(orig) > 60:
        orig = orig[:57] + "..."
    return f"{m.get('mutatorName', '')} `{orig}` -> `{m.get('replacement', '')}`"


def stryker_config(crate):
    """name of the repo's own Stryker config in the crate dir (Stryker reads it), or None."""
    for name in STRYKER_CONFIG_NAMES:
        if os.path.isfile(os.path.join(crate, name)):
            return name
    return None


def line_ranges(lines):
    """sorted line numbers as `a-b` runs of consecutive lines (the form Stryker's --mutate takes)."""
    runs = []
    for n in sorted(set(lines)):
        if runs and runs[-1][1] == n - 1:
            runs[-1][1] = n
        else:
            runs.append([n, n])
    return [f"{a}-{b}" for a, b in runs]


class Stryker:
    """R3 for ts: Stryker 10.0.0 on the changed production lines. `--mutate file:start-end` per changed run: Stryker
    mutates the mutants fully inside a range, so the MISSED list is the changed lines and needs no filter. The repo's
    own Stryker config is kept (Stryker reads it): mutate, the reporter and the test runner (when there is no config)
    are set on the command line, which wins over the file. Results come from the JSON reporter's file, read from
    reports/mutation/mutation.json in the crate dir (Stryker's default; a repo that moves it is n/a). A killed run wrote
    no report, so a budget hit is partial with the mutant count from Stryker's log and no tested count."""
    default_cmd = "node_modules/.bin/stryker"

    def check(self, repo, mb, head, adapter, test_globs, cmd, budget_min, shard, mutant_timeout, runner, project_dir="."):
        cmd = cmd or self.default_cmd
        prod = sorted({ch.new for ch in red.prod_changes(repo, mb, head, adapter, test_globs)
                       if ch.new and _under(ch.new, project_dir)})
        files = shard_files(prod, shard)
        changed = added_lines(repo, mb, head)
        budget = None if budget_min is None else budget_min * 60
        with red.worktree(repo, head) as wt:
            crate = os.path.join(wt, project_dir)
            if not os.path.isdir(crate):
                return _check("fail", f"project dir {project_dir} not found at head: mutants not run"), [
                    finalize([entry("R3", "", 0, "project-dir", "agent-fixable", "fail",
                                    f"project dir {project_dir} not found at head: mutants not run",
                                    "set project-dir to the crate dir under the repo root, present at head",
                                    "a mutation check that did not run")])[0]]
            if not any(os.path.isfile(os.path.join(crate, m)) for m in adapter.manifests):
                return _check("n/a", f"no {red.manifest_label(adapter)} in {project_dir}: set project-dir"), []
            if not files:
                return _check("pass", "0 mutants in the diff (no changed production file in this shard)", 0, 0), []
            adapter.worktree_setup(repo, wt, project_dir)
            rc, text = runner(shlex.split(cmd) + ["--version"], crate, PROBE_TIMEOUT)
            if rc != 0 or not STRYKER_VERSION.search(text or ""):
                return _check("n/a", f"stryker not installed (env): `{cmd}` not runnable; install @stryker-mutator/core "
                                     "10.0.0 and its test runner plugin (ts toolchain step) or set mutants-cmd"), []
            runner_name = ts_runner(crate)
            bin_path = os.path.join("node_modules", ".bin", runner_name)
            if not os.path.isfile(os.path.join(crate, bin_path)):
                return _check("n/a", f"{runner_name} not installed (env): `{bin_path}` not runnable; install the repo's "
                                     "dependencies (ts toolchain step) or set setup-command"), []
            ranges = []
            for f in files:
                crate_f = _crate_path(project_dir, f)
                if "," in crate_f:
                    return _check("n/a", f"{f}: a comma in a file name cannot be passed to stryker --mutate (env)"), []
                ranges += [f"{crate_f}:{r}" for r in line_ranges([ln for ln, _ in changed.get(f, [])])]
            if not ranges:
                return _check("pass", "0 mutants in the diff", 0, 0), []
            report = os.path.join(crate, STRYKER_REPORT)
            if os.path.lexists(report):
                os.remove(report)  # a report the repo itself committed is never read as this run's
            config = stryker_config(crate)
            argv = shlex.split(cmd) + ["run", "--mutate", ",".join(ranges), "--reporters", "json",
                                       "--allowConsoleColors", "false", "--timeoutMS",
                                       str((STRYKER_TIMEOUT if mutant_timeout is None else mutant_timeout) * 1000)]
            if config is None:
                if runner_name == "vitest":
                    _write_stryker_config(crate, VITEST_STRYKER_CONFIG)
                else:
                    argv += ["--testRunner", runner_name]
            t0 = time.monotonic()
            rc, text = runner(argv, crate, budget)
            wall = time.monotonic() - t0
            total = stryker_total(text)
            doc = _load(report)
            if not isinstance(doc, dict):
                doc = None
            timing = {"wall_s": round(wall, 2)}
            if doc is None:
                if rc == "timeout":
                    note = (f"budget hit before Stryker wrote its report (it writes at the end of a run): "
                            f"{total if total is not None else '?'} mutants, none read")
                    return {"status": "partial", "note": note, "tested": None, "total": total, "timing": timing}, []
                if STRYKER_BASELINE in (text or ""):
                    return _check("fail", "baseline tests fail at head: mutants not run"), finalize([
                        entry("R3", "", 0, "baseline", "agent-fixable", "fail", "baseline tests fail at head: mutants not run",
                              "fix the failing tests first: mutation needs an unmutated tree that passes",
                              "a mutation check that did not run")])
                return _check("n/a", f"no Stryker report (env): {_first_line(text) or f'exit {rc}'}; check the test runner "
                                     "plugin and the run log"), []
            try:
                rows = stryker_rows(doc)
            except ValueError as e:
                return _check("n/a", f"Stryker report is malformed (env): {e}; check the Stryker version and the run log"), []
            silent = [m for _, m, _ in rows if m.get("status") == "Survived" and m.get("coveredBy")
                      and not m.get("testsCompleted")]
            if silent:
                return _check("n/a", f"stryker completed no test for {len(silent)} covered mutant(s) (env): the test runner "
                                     "did not run them; known: @stryker-mutator/vitest-runner 10.0.0 with vitest 5 and tests "
                                     "in describe. Use jest, vitest 4, or a repo config that runs the suite per mutant"), []
            caught = 0
            outside = unlocated = 0
            found = []
            for f_key, m, src in rows:
                kind = stryker_kind(m.get("status"))
                if kind == "caught":
                    caught += 1
                if kind != "missed":
                    continue
                file = _repo_path(project_dir, f_key)
                line = ((m.get("location") or {}).get("start") or {}).get("line")
                if not isinstance(line, int):
                    unlocated += 1
                    continue
                if line not in {n for n, _ in changed.get(file, [])}:
                    outside += 1
                    continue
                found.append((file, line, m, stryker_desc(m, src)))
            ents = finalize([
                entry("R3", file, line, f"missed:{file}|{desc}", "agent-fixable", "fail", f"MISSED mutant {file}:{line}: {desc}",
                      (f"add an assert that fails for this mutant: {desc}" if m.get("status") == "Survived" else
                       "no test reaches this line: add a test that calls it and asserts the result"),
                      f"MISSED mutant `{desc}` in `{file}`")
                for file, line, m, desc in found])
            if unlocated:
                ents += finalize([entry("R3", "", 0, "unlocated", "agent-fixable", "confirm",
                                        f"R3 unlocated: {unlocated} missed mutant(s) have no location in the Stryker report: "
                                        "not blocking",
                                        "read checks.R3.note: the report gives no location for these mutants; check them by hand",
                                        "counting an unlocated mutant as outside the diff, or as a fail without a look")])
            fails = sum(1 for e in ents if e["severity"] == "fail")
            if not rows:
                return {"status": "pass", "note": "0 mutants in the diff", "tested": 0, "total": 0, "timing": timing}, ents
            tested = len(rows)
            note = (f"{tested}/{tested} tested: {fails} missed in the diff, {outside} missed outside the diff, "
                    f"{unlocated} unlocated, {caught} caught")
            if config is not None:
                note += f" (repo config {config}: mutate and reporter set on the command line)"
            check = _check("fail" if fails else "pass", note, tested, tested)
            check["timing"] = timing
            return check, ents


TOOLS = {"rust": CargoMutants(), "python": Mutmut(), "ts": Stryker()}


def run(repo, mb, head, adapter, test_globs, cmd=None, budget_min=None, shard=None,
        mutant_timeout=None, runner=None, project_dir="."):
    """R3 for mb..head. Returns (check, entries). Skipped without a production change; n/a without the tool.
    mutant_timeout None is auto (see CargoMutants). The stack's tool runs in the crate dir of a worktree at head
    (the caller's checkout does not move)."""
    runner = runner or default_runner()
    if not red.prod_changes(repo, mb, head, adapter, test_globs):
        return _check("skipped", "no production file changed"), []
    check, ents = TOOLS[adapter.name].check(repo, mb, head, adapter, test_globs, cmd, budget_min, shard,
                                            mutant_timeout, runner, project_dir)
    if check["status"] == "partial":
        ents = ents + [partial_entry(check)]
    return check, ents
