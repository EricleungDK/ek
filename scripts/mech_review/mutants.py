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
  budget hit: partial `tested/total` when no MISSED so far; fail when a MISSED was found.
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
import tempfile
import time

from . import red
from .engine import added_lines, entry, finalize, git

DEFAULT_CMD = "cargo mutants"
MUTANT_TIMEOUT = 120  # seconds per cargo command (cargo-mutants --timeout): a mutant whose tests hang is a TIMEOUT
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
    base = next((oc for oc in (doc or {}).get("outcomes", [])
                 if isinstance(oc, dict) and oc.get("scenario") == "Baseline"), None)
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
    else:
        problem = f"R3 partial: {total - (tested or 0)}/{total} mutants untested at budget"
    e = entry("R3", "", 0, PARTIAL_KEY, "agent-fixable", "confirm", problem,
              "read checks.R3.timing (wall, phase seconds, slowest mutants): shrink the diff first, then narrow the tests "
              "cargo-mutants runs, then raise mutation-budget",
              "treating a partial R3 as tested")
    return finalize([e])[0]


def _repo_path(project_dir, path):
    """cargo-mutants names files relative to the crate dir; the result names them relative to the repo root."""
    return path if project_dir == "." else posixpath.join(project_dir, path)


def verdict(mo, rc, text, adapter, test_globs, wall_s=None, project_dir="."):
    """R3 verdict of one run. mo: the mutants.out directory (cargo-mutants -o DIR writes DIR/mutants.out).
    rc: the exit code, "timeout" (budget killed the run), or None (tool not runnable). text: its output.
    wall_s: the runner's clock for this run, if measured. project_dir: the crate dir under the repo root.
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

    if rc == "timeout":
        shown = f"{tested}/{total if total is not None else '?'}"
        if missed:
            return done(_check("fail", f"{shown} tested: budget hit, {missed} missed", tested, total), entries)
        return done(_check("partial", f"{shown} tested: budget hit, no MISSED so far", tested, total), [])
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


class CargoMutants:
    """R3 for rust: cargo-mutants --in-diff in the crate dir of a worktree at head; verdict from its output files."""
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
            argv = shlex.split(cmd) + ["--in-diff", diff_path, "--timeout", str(mutant_timeout), "--colors", "never",
                                       "--output", out_parent]
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
            check, ents = verdict(os.path.join(out_parent, "mutants.out"), rc, text, adapter, test_globs, wall_s=wall,
                                  project_dir=project_dir)
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


def locate(src, name, removed):
    """1-based line of the removed text inside the function a mutmut name points at (`calc.core.x_add__mutmut_1` ->
    `def add(`), or None. Lines are the file's, so they follow the code when it moves."""
    fn = name.rsplit(".", 1)[-1].split("__mutmut_")[0]
    if fn.startswith("x_"):
        fn = fn[2:]
    lines = (src or "").splitlines()
    start = next((i for i, ln in enumerate(lines) if re.match(rf"\s*(async\s+)?def\s+{re.escape(fn)}\s*\(", ln)), None)
    if start is None:
        return None
    indent = len(lines[start]) - len(lines[start].lstrip())
    end = next((j for j in range(start + 1, len(lines))
                if lines[j].strip() and len(lines[j]) - len(lines[j].lstrip()) <= indent), len(lines))
    for j in range(start, end):
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
                return _check("fail", "baseline tests fail at head: mutants not run"), [
                    entry("R3", "", 0, "baseline", "agent-fixable", "fail", "baseline tests fail at head: mutants not run",
                          "fix the failing tests first: mutation needs an unmutated tree that passes",
                          "a mutation check that did not run")]
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
            found, outside = [], 0
            for name, k, status in rows:
                if k != "missed":
                    continue
                rc_s, show = runner(shlex.split(cmd) + ["show", name], crate, PROBE_TIMEOUT)
                parsed = parse_show(show) if rc_s == 0 else None
                if parsed is None:
                    found.append((name, "", 0, name, status))  # location unknown: kept, conservative
                    continue
                removed, after = parsed
                file = _repo_path(project_dir, show_file(show) or "")
                line = locate(_read(os.path.join(crate, _crate_path(project_dir, file))), name, removed)
                if line is not None and line not in {n for n, _ in changed.get(file, [])}:
                    outside += 1
                    continue
                found.append((name, file, line or 0, f"{removed} -> {after}", status))
            ents = finalize([
                entry("R3", file, line, f"missed:{file}|{desc}", "agent-fixable", "fail", f"MISSED mutant {file}:{line}: {desc}",
                      (f"add an assert that fails for this mutant: {desc}" if status == "survived" else
                       "no test reaches this line: add a test that calls it and asserts the result"),
                      f"MISSED mutant `{desc}` in `{file}`")
                for _, file, line, desc, status in found])
            shown = f"{tested}/{total if total is not None else '?'}"
            timing = {"wall_s": round(wall, 2)}
            if rc == "timeout":
                if ents:
                    check = _check("fail", f"{shown} tested: budget hit, {len(ents)} missed", tested, total)
                else:
                    check = _check("partial", f"{shown} tested: budget hit, no MISSED so far", tested, total)
            else:
                note = f"{shown} tested: {len(ents)} missed in the diff, {outside} missed outside the diff, {caught} caught"
                check = _check("fail" if ents else "pass", note, tested, total)
            check["timing"] = timing
            return check, ents


def _read(path):
    try:
        with open(path, encoding="utf-8", errors="surrogateescape") as f:
            return f.read()
    except OSError:
        return ""


TOOLS = {"rust": CargoMutants(), "python": Mutmut()}


def run(repo, mb, head, adapter, test_globs, cmd=None, budget_min=None, shard=None,
        mutant_timeout=MUTANT_TIMEOUT, runner=None, project_dir="."):
    """R3 for mb..head. Returns (check, entries). Skipped without a production change; n/a without the tool.
    The stack's tool runs in the crate dir of a worktree at head (the caller's checkout does not move)."""
    runner = runner or default_runner()
    if not red.prod_changes(repo, mb, head, adapter, test_globs):
        return _check("skipped", "no production file changed"), []
    check, ents = TOOLS[adapter.name].check(repo, mb, head, adapter, test_globs, cmd, budget_min, shard,
                                            mutant_timeout, runner, project_dir)
    if check["status"] == "partial":
        ents = ents + [partial_entry(check)]
    return check, ents
