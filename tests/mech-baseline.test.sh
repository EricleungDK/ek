#!/bin/bash
# R3 baseline once (#46): the baseline step measures the unmutated tree once (rust: cargo-mutants on one mutant with
# --build-timeout 0, so only the baseline runs); shards skip it and take a per-mutant timeout derived from it; the
# shard count is min(4, mutants) so no shard is empty; combine_timing keeps sums for a shard with 0 tested.
# Fixtures are real cargo-mutants 27.1.0 output (tests/fixtures/mutants/baseline-ok, skip-missed, list-15.json).
source "$(dirname "$0")/lib.sh"
FX="$ROOT/tests/fixtures/mutants"

python3 -I - "$ROOT" <<'PY'
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = sys.argv[1]
sys.path.insert(0, os.path.join(ROOT, "scripts"))
FX = os.path.join(ROOT, "tests", "fixtures", "mutants")
FAILS = 0


def check(name, cond, detail=""):
    global FAILS
    if cond:
        print(f"  ok   {name}")
    else:
        FAILS += 1
        print(f"  FAIL {name}")
        if detail:
            print(f"       {detail}")


def run_check(name, fn, detail=""):
    """run one check; an exception is a failure with its text, so one missing name does not hide the rest.
    fn returns a bool, or (bool, detail); a bare value is the detail when the check fails."""
    try:
        r = fn() if callable(fn) else fn
    except Exception as e:  # noqa: BLE001 - report, keep going
        check(name, False, f"raised {type(e).__name__}: {e}")
        return
    if isinstance(r, tuple):
        check(name, r[0], r[1] if len(r) > 1 else detail)
    else:
        check(name, bool(r), detail)


from mech_review import mutants as M  # noqa: E402
from mech_review import merge  # noqa: E402
from mech_review.stack import RustAdapter, PythonAdapter, TsAdapter  # noqa: E402

A = RustAdapter()
TG = ["tests/**"]
H, B = "a" * 40, "b" * 40


# ---- the per-mutant timeout: cargo-mutants' rule (timeouts.rs test_timeout): max(minimum, ceil(baseline test * multiplier)) ----
run_check("derive: 5x the baseline test time, ceil", lambda: M.derive_timeout(10.0) == 50)
run_check("derive: ceil of the product (4.1 s -> 20.5 -> 21)", lambda: M.derive_timeout(4.1) == 21)
run_check("derive: floor at minimum_test_timeout (20 s default)", lambda: M.derive_timeout(2.0) == 20)
run_check("derive: zero baseline gives the minimum", lambda: M.derive_timeout(0.0) == 20)
run_check("derive: whole seconds print without a decimal (workflow output)", lambda: str(M.derive_timeout(10.0)) == "50")
run_check("derive: explicit multiplier and minimum", lambda: M.derive_timeout(10.0, 3.0, 7.0) == 30)
run_check("derive: minimum wins over a small product", lambda: M.derive_timeout(1.0, 3.0, 7.0) == 7)


def _cfg(text):
    d = tempfile.mkdtemp()
    try:
        if text is not None:
            os.makedirs(os.path.join(d, ".cargo"))
            with open(os.path.join(d, ".cargo", "mutants.toml"), "w") as f:
                f.write(text)
        return M.cargo_config(d)
    finally:
        shutil.rmtree(d, ignore_errors=True)


run_check("config: no .cargo/mutants.toml gives cargo-mutants' defaults (5.0, 20.0)", lambda: _cfg(None) == (5.0, 20.0))
run_check("config: timeout_multiplier and minimum_test_timeout read (snake_case keys, as cargo-mutants reads them)",
          lambda: _cfg("timeout_multiplier = 3.0\nminimum_test_timeout = 7\n") == (3.0, 7.0))
run_check("config: other keys leave the defaults", lambda: _cfg("exclude_re = []\n") == (5.0, 20.0))

# ---- verdict with the baseline skipped (shards): no Baseline outcome is normal, not "baseline did not finish" ----
run_check("skipped baseline: MISSED still fail with one entry per missed mutant",
          lambda: (M.verdict(os.path.join(FX, "skip-missed"), 2, "", A, TG, skipped_baseline=True)[0]["status"] == "fail"
                   and len(M.verdict(os.path.join(FX, "skip-missed"), 2, "", A, TG, skipped_baseline=True)[1]) == 5))
run_check("skipped baseline: all 15 tested, from the mutants alone",
          lambda: M.verdict(os.path.join(FX, "skip-missed"), 0, "", A, TG, skipped_baseline=True)[0].get("tested") == 15)
run_check("skipped baseline: budget hit before any mutant is partial, not a baseline story",
          lambda: (lambda c: (c["status"] == "partial" and "baseline" not in c["note"], str(c)))(
              M.verdict(os.path.join(FX, "no-such-dir"), "timeout", "", A, TG, skipped_baseline=True)[0]))

# ---- baseline timeout note: no longer names mant-timeout (a set mutant-timeout does not cap the baseline any more) ----
BT_NOTE = M.verdict(os.path.join(FX, "baseline-timeout"), 4, "", A, TG, wall_s=1.5, timeout_s=1)[0]["note"]
run_check("baseline timeout note: names the seconds and mutation-budget",
          "1s" in BT_NOTE and "mutation-budget" in BT_NOTE, BT_NOTE)
run_check("baseline timeout note: no longer says mutant-timeout caps the baseline",
          "mutant-timeout caps" not in BT_NOTE, BT_NOTE)

# ---- the baseline step (rust): a fake cargo-mutants that writes real fixtures, git repo at base..head ----
REPO = tempfile.mkdtemp(prefix="mech-baseline-")
GIT = ["git", "-c", "user.name=t", "-c", "user.email=t@t"]


def _repo():
    r = os.path.join(REPO, "r")
    os.makedirs(os.path.join(r, "src"))
    os.makedirs(os.path.join(r, "tests"))
    subprocess.run(["git", "init", "-q", "-b", "main", r], check=True)
    with open(os.path.join(r, "src", "lib.rs"), "w") as f:
        f.write("pub fn add(a: i32, b: i32) -> i32 { a + b }\n")
    with open(os.path.join(r, "tests", "a.rs"), "w") as f:
        f.write("#[test]\nfn adds() {\n    assert_eq!(x::add(1, 2), 3);\n}\n")
    with open(os.path.join(r, "Cargo.toml"), "w") as f:
        f.write('[package]\nname = "x"\nversion = "0.1.0"\n')
    subprocess.run(GIT + ["-C", r, "add", "-A"], check=True)
    subprocess.run(GIT + ["-C", r, "commit", "-qm", "base"], check=True)
    base = subprocess.run(["git", "-C", r, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    with open(os.path.join(r, "src", "lib.rs"), "w") as f:
        f.write("pub fn add(a: i32, b: i32) -> i32 { a + b } // fixed\n")
    subprocess.run(GIT + ["-C", r, "commit", "-qam", "head"], check=True)
    head = subprocess.run(["git", "-C", r, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    return r, base, head


REPO_DIR, BASE_SHA, HEAD_SHA = _repo()
LIST15 = open(os.path.join(FX, "list-15.json")).read()


def fake(list_text=LIST15, list_rc=0, version_rc=0, fixture="baseline-ok", run_rc=3, run_text="", hang=False):
    calls = []

    def run(argv, cwd, budget):
        calls.append((list(argv), cwd, budget))
        if version_rc is None or argv[-1] == "--version":
            return (version_rc, "cargo-mutants 27.1.0" if version_rc == 0 else "not found")
        if "--list" in argv:
            return (list_rc, list_text)
        if hang:
            return ("timeout", "")
        out = argv[argv.index("--output") + 1]
        if fixture:
            dst = os.path.join(out, "mutants.out")
            os.makedirs(dst, exist_ok=True)
            shutil.copytree(os.path.join(FX, fixture), dst, dirs_exist_ok=True)
        return (run_rc, run_text)

    run.calls = calls
    return run


def baseline(runner, shards=4, budget=10, adapter=A, stack_repo=None):
    r = stack_repo or REPO_DIR
    mb = BASE_SHA
    return M.baseline(r, mb, HEAD_SHA, adapter, TG, cmd=None, budget_min=budget, shards=shards, project_dir=".", runner=runner)


f_ok = fake()
p_ok = baseline(f_ok)
run_check("baseline ok: run the shards", p_ok["run"] is True, str(p_ok))
run_check("baseline ok: 15 mutants in the diff", p_ok["mutants"] == 15, str(p_ok.get("mutants")))
run_check("baseline ok: 4 shards (min of the max and the mutant count)", p_ok["count"] == 4, str(p_ok.get("count")))
run_check("baseline ok: per-mutant timeout derived from the measured baseline test (20 s floor here)",
          p_ok["timeout"] == 20, str(p_ok.get("timeout")))
bt = json.load(open(os.path.join(FX, "baseline-ok", "outcomes.json")))
bt = next(o for o in bt["outcomes"] if o["scenario"] == "Baseline")
bt_build = next(p["duration"] for p in bt["phase_results"] if p["phase"] == "Build")
bt_test = next(p["duration"] for p in bt["phase_results"] if p["phase"] == "Test")
t = p_ok["check"].get("timing", {})
run_check("baseline ok: baseline build seconds recorded once in the check timing",
          abs(t.get("baseline_build_s", -1) - bt_build) < 0.01, str(t))
run_check("baseline ok: baseline test seconds recorded once in the check timing",
          abs(t.get("baseline_test_s", -1) - bt_test) < 0.01, str(t))
run_check("baseline ok: the R3 check is not a verdict (shards decide): skipped", p_ok["check"]["status"] == "skipped",
          str(p_ok["check"]))
run_check("baseline ok: no entries", p_ok["entries"] == [], str(p_ok["entries"]))

run_argv = next(a for a, _, _ in f_ok.calls if "--output" in a)
list_argv = next(a for a, _, _ in f_ok.calls if "--list" in a)
run_check("baseline run: only the baseline runs (one mutant, builds killed at 0 s)",
          run_argv[run_argv.index("--build-timeout") + 1] == "0", str(run_argv))
run_check("baseline run: one mutant only (round-robin shard 0 of the count)",
          run_argv[run_argv.index("--shard") + 1] == "0/15" and run_argv[run_argv.index("--sharding") + 1] == "round-robin",
          str(run_argv))
run_check("baseline run: no --timeout (the baseline runs unlimited; the budget bounds it)", "--timeout" not in run_argv,
          str(run_argv))
run_check("baseline run: colour off and --in-diff passed", "--colors" in run_argv and "--in-diff" in run_argv, str(run_argv))
run_check("baseline list: --list --json with the diff, no run", "--json" in list_argv and "--output" not in list_argv,
          str(list_argv))

# baseline fails at head (rc 4): fail, agent-fixable, the log tail on stderr
err = io.StringIO()
with contextlib.redirect_stderr(err):
    p_fail = baseline(fake(fixture="baseline-failure", run_rc=4))
run_check("baseline failure: R3 fail", p_fail["check"]["status"] == "fail" and p_fail["run"] is False, str(p_fail["check"]))
run_check("baseline failure: one agent-fixable entry naming the baseline",
          len(p_fail["entries"]) == 1 and p_fail["entries"][0]["class"] == "agent-fixable"
          and "baseline tests fail at head" in p_fail["entries"][0]["problem"], str(p_fail["entries"]))
run_check("baseline failure: log tail printed to stderr", "baseline" in err.getvalue() and "last" in err.getvalue(),
          err.getvalue()[:300])

# baseline timed out by the budget before it finished: n/a (timeout), never a fail, no shards
p_to = baseline(fake(hang=True, fixture=None), budget=0.02)
run_check("baseline timeout: R3 n/a, not a fail", p_to["check"]["status"] == "n/a", str(p_to["check"]))
run_check("baseline timeout: note says timed out and names mutation-budget",
          "timed out" in p_to["check"]["note"] and "mutation-budget" in p_to["check"]["note"], p_to["check"]["note"])
run_check("baseline timeout: shards do not run", p_to["run"] is False and p_to["count"] == 0, str(p_to))

# no mutants in the diff: pass, no shards
p_none = baseline(fake(list_text=""))
run_check("no mutants: pass with 0 mutants, no shards", p_none["check"]["status"] == "pass" and p_none["run"] is False
          and p_none["count"] == 0 and p_none["mutants"] == 0, str(p_none))

# log lines on stderr come before the JSON array (the runner merges the two streams): still counted
p_noisy = baseline(fake(list_text="INFO found 3 mutants\n" + json.dumps([{"name": "a"}] * 3, indent=2)))
run_check("list with a log line before the JSON: the mutants are counted", p_noisy["mutants"] == 3
          and p_noisy["check"]["status"] == "skipped" and p_noisy["run"] is True, str(p_noisy["check"]))

# list failed (env): n/a, never pass
p_lf = baseline(fake(list_rc=1, list_text="error: could not find Cargo.toml"))
run_check("list failed: n/a (env), never pass", p_lf["check"]["status"] == "n/a" and "(env)" in p_lf["check"]["note"]
          and p_lf["run"] is False, str(p_lf["check"]))

# tool missing: n/a (env)
p_nt = baseline(fake(version_rc=None))
run_check("tool missing: n/a (env), no shards", p_nt["check"]["status"] == "n/a" and p_nt["run"] is False, str(p_nt["check"]))

# shard count: min(max, mutants); a max below the mutant count is the max
run_check("shard count: the max when there are more mutants", baseline(fake(), shards=2)["count"] == 2)
run_check("shard count: the mutant count when fewer than the max (no empty shard)",
          baseline(fake(list_text=json.dumps([{"name": "a"}] * 3)), shards=4)["count"] == 3)

# python: one shard per changed production file (mutmut shards by file), no toolchain
PY_REPO = os.path.join(REPO, "py")
os.makedirs(os.path.join(PY_REPO, "pkg"))
subprocess.run(["git", "init", "-q", "-b", "main", PY_REPO], check=True)
for name in ("a.py", "b.py", "c.py", "d.py", "e.py"):
    with open(os.path.join(PY_REPO, "pkg", name), "w") as f:
        f.write("def f():\n    return 1\n")
with open(os.path.join(PY_REPO, "test_x.py"), "w") as f:
    f.write("def test_x():\n    assert True\n")
subprocess.run(GIT + ["-C", PY_REPO, "add", "-A"], check=True)
subprocess.run(GIT + ["-C", PY_REPO, "commit", "-qm", "base"], check=True)
PY_BASE = subprocess.run(["git", "-C", PY_REPO, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
for name in ("a.py", "b.py", "c.py", "d.py", "e.py"):
    with open(os.path.join(PY_REPO, "pkg", name), "w") as f:
        f.write("def f():\n    return 2\n")
subprocess.run(GIT + ["-C", PY_REPO, "commit", "-qam", "head"], check=True)
PY_HEAD = subprocess.run(["git", "-C", PY_REPO, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
p_py = M.baseline(PY_REPO, PY_BASE, PY_HEAD, PythonAdapter(), ["test_*.py"], shards=4, runner=fake())
run_check("python: 5 changed files, 4 shards (min of 4 and the file count)", p_py["count"] == 4 and p_py["run"] is True,
          str(p_py))
run_check("python: no timeout and no mutant count (mutmut counts its own)", p_py["timeout"] is None and p_py["mutants"] is None,
          str(p_py))
p_py1 = M.baseline(PY_REPO, PY_BASE, PY_HEAD, PythonAdapter(), ["test_*.py"], shards=1, runner=fake())
run_check("python: a max of 1 gives one shard", p_py1["count"] == 1, str(p_py1))
p_ts_none = M.baseline(PY_REPO, PY_HEAD, PY_HEAD, TsAdapter(), ["**/*.test.ts"], shards=4, runner=fake())
run_check("no production change: skipped, no shards", p_ts_none["check"]["status"] == "skipped" and p_ts_none["run"] is False,
          str(p_ts_none))

# ---- merge: the baseline envelope (what `baseline` prints) decides when no shard runs; shards merge when it ran; timing once ----
def env(entries, r3):
    return {"ekit": "x", "base": B, "head": H, "checks": {"R3": r3}, "entries": entries, "summary": "x"}


def r3(status, note="x", tested=None, total=None, timing=None):
    c = {"status": status, "note": note}
    if tested is not None:
        c["tested"] = tested
        c["total"] = total
    if timing is not None:
        c["timing"] = timing
    return c


def mis(eid, line=2):
    return {"id": eid, "check": "R3", "class": "agent-fixable", "severity": "fail", "file": "src/lib.rs", "line": line,
            "problem": f"MISSED {eid}", "hint": "h", "forbidden": "f"}


base_fail = {"run": False, "count": 0, "mutants": 15, "timeout": None, "base": B, "head": H,
             "checks": {"R3": r3("fail", "baseline tests fail at head: mutants not run")},
             "entries": [mis("R3-deadbeef")]}
m = merge.combine_mutants(B, H, 0, {}, {}, baseline=base_fail)
run_check("merge: baseline fail, no shards: R3 is the baseline's fail", m["checks"]["R3"]["status"] == "fail"
          and m["checks"]["R3"]["note"].startswith("baseline tests fail"), str(m["checks"]["R3"]))
run_check("merge: baseline fail keeps its entry, adds no CI entry",
          [e["id"] for e in m["entries"]] == ["R3-deadbeef"], str(m["entries"]))

base_none = None
m = merge.combine_mutants(B, H, 1, {}, {0: "no result file given"}, baseline=base_none, baseline_reason="no JSON from the job")
run_check("merge: no baseline result: R3 fail with a CI entry naming the baseline job",
          m["checks"]["R3"]["status"] == "fail" and any(e["check"] == "CI" and "baseline" in e["problem"] for e in m["entries"]),
          str(m["entries"]))

base_run = {"run": True, "count": 2, "mutants": 4, "timeout": 20, "base": B, "head": H,
            "checks": {"R3": r3("skipped", "baseline ok", timing={"wall_s": 9.0, "baseline_build_s": 2.0, "baseline_test_s": 3.0})},
            "entries": []}
s0 = env([mis("R3-aaaaaaaa", 2)], r3("fail", "1/2 tested", 2, 2, {"wall_s": 4.0, "mutant_build_s": 1.0, "mutant_test_s": 2.0,
                                                                  "avg_s_per_mutant": 1.5}))
s1 = env([], r3("pass", "2/2 tested", 2, 2, {"wall_s": 6.0, "mutant_build_s": 1.5, "mutant_test_s": 2.5,
                                             "avg_s_per_mutant": 2.0}))
m = merge.combine_mutants(B, H, 2, {0: s0, 1: s1}, {}, baseline=base_run)
t = m["checks"]["R3"].get("timing", {})
run_check("merge: baseline ran: shards merge (one fail entry kept)", m["checks"]["R3"]["status"] == "fail"
          and [e["id"] for e in m["entries"]] == ["R3-aaaaaaaa"], str(m["checks"]["R3"]))
run_check("merge: mutant build summed over the shards, baseline not added to it",
          abs(t.get("mutant_build_s", -1) - 2.5) < 0.01, str(t))
run_check("merge: mutant test summed over the shards", abs(t.get("mutant_test_s", -1) - 4.5) < 0.01, str(t))
run_check("merge: baseline build seconds once", t.get("baseline_build_s") == 2.0, str(t))
run_check("merge: baseline test seconds once", t.get("baseline_test_s") == 3.0, str(t))
run_check("merge: average over the 4 tested mutants", abs(t.get("avg_s_per_mutant", -1) - 1.75) < 0.01, str(t))
run_check("merge: no CI entry for a planned shard set (every shard reported)",
          not any(e["check"] == "CI" for e in m["entries"]), str(m["entries"]))
run_check("merge: a shard that never ran is still a CI fail (the set is 2, one missing)",
          any(e["check"] == "CI" for e in merge.combine_mutants(B, H, 2, {0: s0}, {1: "no result file given"},
                                                                   baseline=base_run)["entries"]))

# combine_timing: a shard with 0 tested counts as zero; a missing shard still drops the sums (#46 bug)
zero = (("1/2", None, 0), )
mt = merge.combine_timing([("0/2", {"wall_s": 4.0, "mutant_build_s": 1.0, "mutant_test_s": 2.0, "avg_s_per_mutant": 1.5}, 2),
                           ("1/2", {"wall_s": 0.5}, 0)], 2)
run_check("combine_timing: 0-tested shard with no sums keeps the build and test sums", mt.get("mutant_build_s") == 1.0
          and mt.get("mutant_test_s") == 2.0, str(mt))
run_check("combine_timing: 0-tested shard keeps the average (2 mutants)", mt.get("avg_s_per_mutant") == 1.5, str(mt))
run_check("combine_timing: 0-tested shard still gives the slowest shard's wall", mt.get("wall_s") == 4.0, str(mt))
mt = merge.combine_timing([("0/2", {"wall_s": 4.0, "mutant_build_s": 1.0, "mutant_test_s": 2.0}, 2), ("1/2", None, None)], 2)
run_check("combine_timing: a crashed shard (no result) still drops the sums", "mutant_build_s" not in mt, str(mt))
mt = merge.combine_timing([("0/2", {"wall_s": 4.0, "mutant_build_s": 1.0, "mutant_test_s": 2.0}, 2),
                           ("1/2", {"wall_s": 4.0, "mutant_build_s": 3.0, "mutant_test_s": 1.0}, 2)], 4,
                          baseline_timing={"baseline_build_s": 2.0, "baseline_test_s": 3.0})
run_check("combine_timing: baseline seconds from the baseline, once, not summed over shards",
          mt.get("baseline_build_s") == 2.0 and mt.get("baseline_test_s") == 3.0, str(mt))

# ---- engine: the mutants argv (shards skip the baseline; auto keeps cargo-mutants' own inline baseline) ----
mrun = fake()
M.CargoMutants().check(REPO_DIR, BASE_SHA, HEAD_SHA, A, TG, None, 10, "1/2", 30, mrun, ".")
shard_argv = next(a for a, _, _ in mrun.calls if "--in-diff" in a and "--list" not in a)
run_check("shard with a timeout: baseline skipped", shard_argv[shard_argv.index("--baseline") + 1] == "skip", str(shard_argv))
run_check("shard with a timeout: explicit --timeout N", shard_argv[shard_argv.index("--timeout") + 1] == "30", str(shard_argv))
run_check("shard: round-robin so the shards are balanced and none is empty",
          shard_argv[shard_argv.index("--sharding") + 1] == "round-robin" and "--shard" in shard_argv, str(shard_argv))
mrun = fake()
M.CargoMutants().check(REPO_DIR, BASE_SHA, HEAD_SHA, A, TG, None, 10, None, None, mrun, ".")
auto_argv = next(a for a, _, _ in mrun.calls if "--in-diff" in a and "--list" not in a)
run_check("auto (no timeout): no --baseline skip, no --timeout (cargo-mutants' own inline baseline)",
          "--baseline" not in auto_argv and "--timeout" not in auto_argv, str(auto_argv))

shutil.rmtree(REPO, ignore_errors=True)
sys.exit(1 if FAILS else 0)
PY
eq "$?" 0 "baseline once: derive, config, skipped verdict, baseline step, merge, combine_timing, shard argv"

# ---- CLI: baseline, merge --baseline, plan, shards (cargo-mutants stub: --list --json, a run with --output, MUT_RC) ----
MR="$ROOT/scripts/mech-review.py"
T="$(mktemp -d)"
# clean the temp dir with python (no rm -rf on a variable): removed on exit
cleanup() { python3 -I -c 'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' "$T"; }
trap cleanup EXIT
export MECH_FX="$FX" MECH_STUB_LOG="$T/calls.log"; : > "$MECH_STUB_LOG"
MUT="$T/mutstub.sh"
cat > "$MUT" <<'SH'
#!/bin/bash
if [[ "$1" == mutants && "$2" == --version ]]; then echo "cargo-mutants 27.1.0"; exit 0; fi
out=""; shard=""; prev=""; list=""
for a in "$@"; do
  case "$prev" in -o|--output) out="$a" ;; --shard) shard="$a" ;; --in-diff) cp "$a" "$MECH_STUB_LOG.diff" ;; esac
  [[ "$a" == --list ]] && list=1
  prev="$a"
done
echo "$(pwd -P) | $*" >> "$MECH_STUB_LOG"
if [[ -n "$list" ]]; then
  if [[ -n "${MUT_LIST_RC-}" ]]; then echo "error: list failed" >&2; exit "$MUT_LIST_RC"; fi
  cat "$MECH_FX/${MUT_LIST:-list-15.json}"; exit 0
fi
k=${shard%%/*}
if [[ -n "${MUT_FIXTURE-}" && -n "$out" ]]; then
  fx="${MUT_FIXTURE//\{k\}/$k}"
  mkdir -p "$out/mutants.out"; cp -r "$MECH_FX/$fx/." "$out/mutants.out/"
fi
if [[ -n "${MUT_HANG-}" ]]; then sleep 30; fi
exit "${MUT_RC:-0}"
SH
chmod +x "$MUT"

# mrepo <name>: base, then head changing src/lib.rs. sets R B H
mrepo() {
  R="$T/$1"; mkdir -p "$R/src" "$R/tests"; git -C "$R" init -q -b main
  printf 'pub fn add(a: i32, b: i32) -> i32 { a + b }\n' > "$R/src/lib.rs"
  printf '#[test]\nfn adds() {\n    assert_eq!(add(1, 2), 3);\n}\n' > "$R/tests/a.rs"
  printf '[package]\nname = "x"\nversion = "0.1.0"\n' > "$R/Cargo.toml"
  git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@t commit -qm base; B=$(git -C "$R" rev-parse HEAD)
  printf 'pub fn add(a: i32, b: i32) -> i32 { a + b } // fixed\n' > "$R/src/lib.rs"
  git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@t commit -qm head; H=$(git -C "$R" rev-parse HEAD)
}
# bl <args>: the baseline step on $R $B $H with the stub
bl() { MECH_TEST_STUB="$MUT" python3 -I "$MR" baseline --repo "$R" --base "$B" --head "$H" --stack rust --test-paths 'tests/**' "$@"; }
mut() { MECH_TEST_STUB="$MUT" python3 -I "$MR" mutants --repo "$R" --base "$B" --head "$H" --stack rust --test-paths 'tests/**' "$@"; }

# baseline ok: runs the shards, 4 shards, derived timeout (20 s floor), one mutant run for the baseline only
mrepo bok
: > "$MECH_STUB_LOG"
out=$(MUT_FIXTURE=baseline-ok MUT_RC=3 bl --shards 4); rc=$?
eq "$rc" 0 "baseline ok CLI: exit 0"
eq "$(jq -c '{run,count,mutants,timeout}' <<<"$out")" '{"run":true,"count":4,"mutants":15,"timeout":20}' "baseline ok CLI: run, 4 shards, 15 mutants, timeout 20"
eq "$(jq -r .checks.R3.status <<<"$out")" skipped "baseline ok CLI: R3 left to the shards"
has "$(cat "$MECH_STUB_LOG")" "--list --json" "baseline ok CLI: the mutant list is read first"
has "$(cat "$MECH_STUB_LOG")" "--build-timeout 0" "baseline ok CLI: mutant builds killed at 0 s"
has "$(cat "$MECH_STUB_LOG")" "--shard 0/15" "baseline ok CLI: one mutant (round-robin shard 0 of 15)"
lacks "$(cat "$MECH_STUB_LOG")" " --timeout" "baseline ok CLI: no --timeout (a set mutant-timeout never caps the baseline)"
eq "$(jq -r .checks.R3.timing.baseline_test_s <<<"$out")" "$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(round(next(p["duration"] for o in d["outcomes"] if o["scenario"]=="Baseline" for p in o["phase_results"] if p["phase"]=="Test"),2))' "$FX/baseline-ok/outcomes.json")" "baseline ok CLI: baseline test seconds from the baseline"

# baseline fails at head (exit 4): R3 fail, shards not run, the log tail on stderr, exit 0 (a result)
mrepo bfail
out=$(MUT_FIXTURE=baseline-failure MUT_RC=4 bl 2>"$T/bf.err"); rc=$?
eq "$rc" 0 "baseline fail CLI: exit 0 (a result, not a usage error)"
eq "$(jq -c '{run,count}' <<<"$out")" '{"run":false,"count":0}' "baseline fail CLI: no shards"
eq "$(jq -r .checks.R3.status <<<"$out")" fail "baseline fail CLI: R3 fail"
eq "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable "baseline fail CLI: entry agent-fixable"
has "$(cat "$T/bf.err")" "mech-review: R3 fail: last" "baseline fail CLI: log tail header on stderr"
lacks "$out" "baseline line" "baseline fail CLI: no log text on stdout"

# baseline timed out by the budget before it finished: R3 n/a, shards not run
mrepo bto
SECONDS=0
out=$(MUT_HANG=1 bl --mutation-budget 0.02); rc=$?
eq "$rc" 0 "baseline timeout CLI: exit 0"
eq "$(jq -r .checks.R3.status <<<"$out")" n/a "baseline timeout CLI: R3 n/a, not fail"
has "$(jq -r .checks.R3.note <<<"$out")" "timed out" "baseline timeout CLI: note says timed out"
has "$(jq -r .checks.R3.note <<<"$out")" "mutation-budget" "baseline timeout CLI: note names mutation-budget"
eq "$(jq -r .run <<<"$out")" false "baseline timeout CLI: shards not run"
[[ $SECONDS -lt 10 ]] && ok "baseline timeout CLI: budget kill is prompt" || fail "baseline timeout CLI: took ${SECONDS}s"

# no mutants in the diff: pass, no shards
mrepo bnone
out=$(MUT_LIST=list-none.json bl); rc=$?
eq "$(jq -c '{run,count,mutants}' <<<"$out")" '{"run":false,"count":0,"mutants":0}' "no mutants CLI: no shards, 0 mutants"
eq "$(jq -r .checks.R3.status <<<"$out")" pass "no mutants CLI: R3 pass"

# list failed (env): n/a, never pass
mrepo blist
out=$(MUT_LIST_RC=1 bl); rc=$?
eq "$(jq -r .checks.R3.status <<<"$out")" n/a "list failed CLI: R3 n/a"
has "$(jq -r .checks.R3.note <<<"$out")" "(env)" "list failed CLI: note says env"

# usage: at least one shard
mrepo bzero
bl --shards 0 >/dev/null 2>&1; rc=$?
eq "$rc" 2 "baseline --shards 0: usage error exit 2"

# plan: whether R3 runs; the CLI keeps its matrix for the file-sharded stacks, the workflow reads run only (#46)
mrepo pl
out=$(python3 -I "$MR" plan --repo "$R" --base "$B" --head "$H" --stack rust --test-paths 'tests/**'); rc=$?
eq "$rc" 0 "plan: exit 0"
eq "$(jq -c '{run,count,shards}' <<<"$out")" '{"run":true,"count":1,"shards":[0]}' "plan: run true; placeholder matrix (count from baseline)"
mrepo pldocs
printf 'notes\n' > "$R/README.md"; git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@t commit -qm docs; H2=$(git -C "$R" rev-parse HEAD)
out=$(python3 -I "$MR" plan --repo "$R" --base "$H" --head "$H2" --stack rust --test-paths 'tests/**')
eq "$(jq -c '{run}' <<<"$out")" '{"run":false}' "plan: docs-only: run false"

# merge with the baseline: shards merge when it ran; baseline timing once; a shard that never ran is a CI fail
mrepo mrg
BLF="$T/bl-ok.json"; MUT_FIXTURE=baseline-ok MUT_RC=3 bl --shards 4 > "$BLF"
MUT_FIXTURE=missed MUT_RC=2 mut --shard 0/2 > "$T/s0.json"
MUT_FIXTURE=caught MUT_RC=0 mut --shard 1/2 > "$T/s1.json"
mg() { python3 -I "$MR" merge --repo "$R" --base "$B" --head "$H" --stack rust "$@"; }
out=$(mg --baseline "$BLF" --shards 2 --envelope 0="$T/s0.json" --envelope 1="$T/s1.json"); rc=$?
eq "$rc" 1 "merge with baseline: 11 MISSED in shard 0: exit 1"
eq "$(jq -r '[.entries[] | select(.check=="R3")] | length' <<<"$out")" 11 "merge with baseline: 11 R3 entries from the shards"
eq "$(jq -r '[.entries[] | select(.check=="CI")] | length' <<<"$out")" 0 "merge with baseline: no CI entry (no planned-out shard is missing)"
eq "$(jq -r .checks.R3.timing.baseline_test_s <<<"$out")" "$(jq -r .checks.R3.timing.baseline_test_s "$BLF")" "merge with baseline: baseline test seconds once"
eq "$(jq -r .checks.R3.timing.baseline_build_s <<<"$out")" "$(jq -r .checks.R3.timing.baseline_build_s "$BLF")" "merge with baseline: baseline build seconds once"
out=$(mg --baseline "$BLF" --shards 2 --envelope 0="$T/s0.json"); rc=$?
eq "$(jq -r '[.entries[] | select(.check=="CI")][0].problem' <<<"$out")" "mutants shard 1/2 produced no result: no result file given" "merge with baseline: a shard missing is still a CI fail"

# a shard that tested nothing (0 mutants in its slice) keeps the sums of the others (bug #46): build and test still there
MUT_RC=0 mut --shard 1/2 > "$T/s2.json"
eq "$(jq -r .checks.R3.tested <<<"$(cat "$T/s2.json")")" 0 "0-tested shard: tested 0"
out=$(mg --baseline "$BLF" --shards 2 --envelope 0="$T/s0.json" --envelope 1="$T/s2.json")
has "$(jq -c .checks.R3.timing <<<"$out")" "mutant_build_s" "merge: a 0-tested shard keeps the build sum"
has "$(jq -c .checks.R3.timing <<<"$out")" "mutant_test_s" "merge: a 0-tested shard keeps the test sum"
has "$(jq -c .checks.R3.timing <<<"$out")" "avg_s_per_mutant" "merge: a 0-tested shard keeps the average"

# baseline failed: its R3 is the result; no shard needed, no CI entry for the missing shards
BLFAIL="$T/bl-fail.json"; MUT_FIXTURE=baseline-failure MUT_RC=4 bl > "$BLFAIL" 2>/dev/null
out=$(mg --baseline "$BLFAIL" --shards 0); rc=$?
eq "$rc" 1 "merge baseline fail: exit 1 (fail entry)"
eq "$(jq -r .checks.R3.status <<<"$out")" fail "merge baseline fail: R3 fail"
eq "$(jq -r '[.entries[] | select(.check=="CI")] | length' <<<"$out")" 0 "merge baseline fail: no CI entry for shards that never ran"
eq "$(jq -r '[.entries[] | select(.check=="R3")] | length' <<<"$out")" 1 "merge baseline fail: the baseline's one entry"

# no baseline result at all (the baseline job crashed): R3 fail with a CI entry that names the baseline job
out=$(mg --baseline-reason "no JSON from the job (see its log)" --shards 2); rc=$?
eq "$rc" 1 "merge no baseline: exit 1"
has "$(jq -r '[.entries[] | select(.check=="CI")][0].problem' <<<"$out")" "baseline job produced no result" "merge no baseline: CI entry names the baseline job"
eq "$(jq -r .checks.R3.status <<<"$out")" fail "merge no baseline: R3 fail"

# shard runs: the baseline is skipped and the derived timeout is explicit; the auto path keeps cargo-mutants' own
mrepo sh
: > "$MECH_STUB_LOG"
out=$(MUT_FIXTURE=caught MUT_RC=0 mut --shard 1/2 --mutant-timeout 30); rc=$?
has "$(cat "$MECH_STUB_LOG")" "--baseline skip" "shard with a timeout: baseline skipped"
has "$(cat "$MECH_STUB_LOG")" "--timeout 30" "shard with a timeout: explicit --timeout"
has "$(cat "$MECH_STUB_LOG")" "--sharding round-robin" "shard: round-robin"
: > "$MECH_STUB_LOG"
out=$(MUT_FIXTURE=caught MUT_RC=0 mut --shard 1/2); rc=$?
lacks "$(cat "$MECH_STUB_LOG")" "--baseline skip" "shard auto: no --baseline skip (cargo-mutants runs its own baseline)"

done_tests
