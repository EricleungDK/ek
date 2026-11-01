"""R1 red-first and R4 determinism: run the tests a branch adds or changes, through an injectable runner.

runner(argv, cwd) -> (rc, output). rc: int exit code, "timeout", or None (executable missing: toolchain absent).
Tests run in a `git worktree` at the red commit (R1) or at head (R4), like can-fail: the caller's working tree never moves.
Vocabulary of verdicts: see stack.Adapter.outcome.
"""
import contextlib
import os
import shutil
import subprocess
import tempfile

from .engine import changes, blob, entry, git

TEST_RUNS = 5  # R4: each new or changed test, this many times at head
TEST_TIMEOUT = 900  # seconds per run; a timeout is a verdict, not a crash
RED_PREFIX = "test(red)"


def default_runner():
    """Real runner. MECH_TEST_STUB, when set, replaces the toolchain executable (argv[0]); the arguments stay."""
    stub = os.environ.get("MECH_TEST_STUB")

    def run(argv, cwd):
        if stub:
            argv = [stub] + argv[1:]
        try:
            r = subprocess.run(argv, cwd=cwd, capture_output=True, timeout=TEST_TIMEOUT)
        except FileNotFoundError:
            return None, f"{argv[0]}: not found"
        except subprocess.TimeoutExpired:
            return "timeout", ""
        return r.returncode, (r.stdout + r.stderr).decode("utf-8", "replace")

    return run


@contextlib.contextmanager
def worktree(repo, sha):
    """Detached checkout of sha in a temp dir; removed and pruned on exit, the caller's checkout untouched."""
    tmp = tempfile.mkdtemp(prefix="mech-wt-")
    wt = os.path.join(tmp, "wt")
    try:
        git(repo, "worktree", "add", "--detach", wt, sha)
        yield wt
    finally:
        subprocess.run(["git", "-C", repo, "worktree", "remove", "--force", wt], capture_output=True)
        shutil.rmtree(tmp, ignore_errors=True)
        subprocess.run(["git", "-C", repo, "worktree", "prune"], capture_output=True)


def check(status, note):
    return {"status": status, "note": note}


def prod_changes(repo, a, b, adapter, test_globs):
    """changes between a and b that touch a production file (a deleted one counts)."""
    return [ch for ch in changes(repo, a, b) if adapter.classify(ch.new or ch.old, test_globs) == "prod"]


def touched(repo, a, b, adapter, test_globs):
    """[(path, name, line)] of #[test] fns new or changed between a (before) and b (after)."""
    out = []
    for ch in changes(repo, a, b):
        if ch.new is None or adapter.classify(ch.new, test_globs) is None:
            continue
        after = adapter.test_bodies(blob(repo, b, ch.new))
        before = adapter.test_bodies(blob(repo, a, ch.old)) if ch.old else {}
        for name, (line, body) in sorted(after.items(), key=lambda kv: kv[1][0]):
            if name not in before or before[name][1] != body:
                out.append((ch.new, name, line))
    return out


def first_red(repo, mb, head):
    """sha of the first test(red) commit in mb..head (oldest first), or None."""
    for line in git(repo, "log", "--reverse", "--format=%H%x00%s", f"{mb}..{head}").splitlines():
        sha, _, subject = line.partition("\0")
        if subject.startswith(RED_PREFIX):
            return sha
    return None


def run_named(runner, adapter, cmd, cwd, name):
    """(verdict, first line of output): the line says why a run had no test result."""
    rc, out = runner(adapter.test_argv(cmd, name), cwd)
    lines = [l.strip() for l in out.splitlines() if l.strip()]
    return adapter.outcome(rc, out), (lines[0][:200] if lines else "")


def r1(repo, mb, head, adapter, test_globs, head_branch, agent_prefix, cmd, runner):
    """R1 red-first. Returns (check, entries)."""
    if head_branch is None:
        return check("skipped", "no --head-branch: cannot tell an agent branch"), []
    if not head_branch.startswith(agent_prefix):
        return check("skipped", f"branch {head_branch} does not match the agent prefix {agent_prefix}"), []
    if not prod_changes(repo, mb, head, adapter, test_globs):
        return check("skipped", "no production file changed"), []
    red = first_red(repo, mb, head)
    hint = "commit the failing tests first as `test(red): ...`, touching test paths only"
    if red is None:
        return check("fail", "no test(red) commit in base..head"), [
            entry("R1", "", 0, "no-red", "agent-fixable", "fail", "no test(red) commit in base..head",
                  hint, "no failing test(red) commit")]
    parent = f"{red}^"
    prod = prod_changes(repo, parent, red, adapter, test_globs)
    if prod:
        entries = [entry("R1", ch.new or ch.old, 0, f"prod:{ch.new or ch.old}", "agent-fixable", "fail",
                         f"red commit touches production path {ch.new or ch.old}",
                         "move the production change out of the red commit; red is test paths only",
                         "no failing test(red) commit") for ch in prod]
        return check("fail", "red commit touches production"), entries
    tests = touched(repo, parent, red, adapter, test_globs)
    if not tests:
        return check("fail", "red commit adds no new test"), [
            entry("R1", "", 0, "no-tests", "agent-fixable", "fail", "test(red) commit adds no new test",
                  "add the failing test in the red commit", "no failing test(red) commit")]
    entries, red_count, compile_red = [], 0, 0
    with worktree(repo, red) as wt:
        for path, name, line in tests:
            verdict, first = run_named(runner, adapter, cmd, wt, name)
            if verdict == "env":
                return check("n/a", "toolchain absent: cannot run tests at the red commit (env)"), []
            if verdict == "fail":
                red_count += 1
            elif verdict == "build":
                compile_red += 1
                entries.append(entry("R1", path, line, f"compile-red:{name}", "agent-fixable", "confirm",
                                     f"compile-red: red commit does not build, `{name}` counts as red",
                                     "reviewer confirms the build failure is the ticket's reason, not a typo",
                                     "no failing test(red) commit"))
            elif verdict == "pass":
                entries.append(entry("R1", path, line, f"red-pass:{name}", "agent-fixable", "fail",
                                     f"new test `{name}` passes at the red commit",
                                     "write the test so it fails for the ticket's reason before the fix",
                                     "no failing test(red) commit"))
            else:
                entries.append(entry("R1", path, line, f"red-unproven:{name}", "agent-fixable", "fail",
                                     f"`{name}` cannot be proven red at the red commit ({verdict}: {first})",
                                     hint, "no failing test(red) commit"))
    note = f"{red_count} red test(s) fail at the red commit"
    if compile_red:
        note += f"; {compile_red} compile-red"
    return check("fail" if any(e["severity"] == "fail" for e in entries) else "pass", note), entries


def r4(repo, mb, head, adapter, test_globs, cmd, runner):
    """R4 determinism: each new or changed test runs TEST_RUNS times at head; any failing run is a fail. Returns (check, entries)."""
    tests = touched(repo, mb, head, adapter, test_globs)
    if not tests:
        return check("pass", "0 new or changed tests"), []
    entries = []
    with worktree(repo, head) as wt:
        for path, name, line in tests:
            verdicts = []
            for _ in range(TEST_RUNS):
                verdict, first = run_named(runner, adapter, cmd, wt, name)
                if verdict == "env":
                    return check("n/a", "toolchain absent: cannot run new or changed tests (env)"), []
                if verdict == "build":
                    entries.append(entry("R4", path, line, f"build:{name}", "agent-fixable", "fail",
                                         f"does not build at head: `{name}` cannot run",
                                         "fix the build: new or changed tests must run", "a test that does not build"))
                    return check("fail", "does not build at head"), entries
                if verdict == "error":
                    entries.append(entry("R4", path, line, f"cannot-run:{name}", "env", "fail",
                                         f"test `{name}` cannot run at head: {first}",
                                         "fix the test setup (manifest, flags); the toolchain did not reach a test result",
                                         "a check that did not run"))
                    return check("fail", "a new or changed test cannot run at head"), entries
                verdicts.append(verdict)
            bad = [v for v in verdicts if v != "pass"]
            if not bad:
                continue
            if len(bad) == TEST_RUNS and all(v == "none" for v in bad):
                problem = f"test `{name}` did not run at head"
            else:
                kinds = ", ".join(sorted(set(bad)))
                problem = f"test `{name}` failed {len(bad)} of {TEST_RUNS} runs at head ({kinds})"
            entries.append(entry("R4", path, line, f"flaky:{name}", "agent-fixable", "fail", problem,
                                 "find the nondeterminism (time, order, shared state, sleep) and fix it; never retry to green",
                                 "retrying a test until it passes"))
    status = "fail" if entries else "pass"
    return check(status, f"{len(tests)} new or changed test(s) run {TEST_RUNS}x at head"), entries
