"""R1 red-first and R4 determinism: run the tests a branch adds or changes, through an injectable runner.

runner(argv, cwd) -> (rc, output). rc: int exit code, "timeout", or None (executable missing: toolchain absent).
Tests run in a `git worktree` at the red commit (R1) or at head (R4), like can-fail: the caller's working tree never moves.
Vocabulary of verdicts: see stack.Adapter.outcome.
"""
import contextlib
import os
import shlex
import shutil
import subprocess
import tempfile

from .engine import changes, blob, entry, git
from .globs import any_glob

TEST_RUNS = 5  # R4: each new or changed test, this many times at head
TEST_TIMEOUT = 900  # seconds per run; a timeout is a verdict, not a crash


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
        text_after = blob(repo, b, ch.new)
        if adapter.parse_error(text_after):
            continue  # reported by unparseable(): its tests cannot be named
        after = adapter.test_bodies(text_after)
        text_before = blob(repo, a, ch.old) if ch.old else None
        before = adapter.test_bodies(text_before) if text_before is not None and not adapter.parse_error(text_before) else {}
        for name, (line, body) in sorted(after.items(), key=lambda kv: kv[1][0]):
            if name not in before or before[name][1] != body:
                out.append((ch.new, name, line))
    return out


def unparseable(repo, a, b, adapter, test_globs):
    """R4 fail entries for changed files at b that the stack cannot parse: their tests cannot run."""
    out = []
    for ch in changes(repo, a, b):
        if ch.new is None or adapter.classify(ch.new, test_globs) is None:
            continue
        err = adapter.parse_error(blob(repo, b, ch.new))
        if err:
            out.append(entry("R4", ch.new, err[0], f"unparseable:{ch.new}", "agent-fixable", "fail",
                             f"file does not parse: {err[1]} (line {err[0]})",
                             "fix the syntax error: the tests in this file cannot run",
                             "a check that did not run"))
    return out


def run_named(runner, adapter, cmd, cwd, path, name):
    """(verdict, first line of output): the line says why a run had no test result."""
    rc, out = runner(adapter.test_argv(cmd, path, name), cwd)
    lines = [l.strip() for l in out.splitlines() if l.strip()]
    return adapter.outcome(rc, out), (lines[0][:200] if lines else "")


def run_in(runner, adapter, cmd, wt, project_dir, path, name):
    """run_named in the crate dir. A dir missing in this commit is an error verdict (the test cannot run), not a missing toolchain.
    The test's path is given crate-relative (what pytest and unittest name tests by); the verdict is the same either way."""
    cwd = os.path.join(wt, project_dir)
    if not os.path.isdir(cwd):
        return "error", f"project dir {project_dir} not in this commit"
    rel = path[len(project_dir) + 1:] if project_dir != "." and path.startswith(project_dir + "/") else path
    return run_named(runner, adapter, cmd, cwd, rel, name)


def manifest_label(adapter):
    """`Cargo.toml`, or `pyproject.toml, setup.py or setup.cfg`: how a hint names the project's manifest files."""
    names = list(adapter.manifests)
    return names[0] if len(names) == 1 else ", ".join(names[:-1]) + " or " + names[-1]


def no_manifest_hint(adapter, wt, project_dir):
    """an existing project dir with none of the stack's manifest files. Returns the hint suffix naming project-dir, or ''."""
    cwd = os.path.join(wt, project_dir)
    if adapter.manifests and os.path.isdir(cwd) and not any(os.path.isfile(os.path.join(cwd, m)) for m in adapter.manifests):
        return f"; no {manifest_label(adapter)} in {project_dir}: set project-dir"
    return ""


def absent(cmd, what, first=""):
    """n/a note for a toolchain or test runner that is not installed: names the tool and the input that installs it."""
    if "No module named" in first:  # python: the runner is there, its test deps are not
        name = "pytest" if "pytest" in first else "test runner"
        return f"{name} not installed (env): `{first}`: install the test deps, or set setup-command ({what})"
    return f"toolchain absent: `{shlex.split(cmd)[0]}` not found (env): install it, or set setup-command ({what})"


def overlay_tests(repo, wt, mb, head, test_globs):
    """In a worktree at mb, put head's version of every file under test_globs the PR changed (deleted ones go), so the
    PR's tests meet the base's production code. Returns the changed test-path files at head."""
    out = []
    for ch in changes(repo, mb, head):
        if ch.old and any_glob(ch.old, test_globs) and ch.old != ch.new:
            git(wt, "rm", "-q", "--ignore-unmatch", "--", ch.old)
        if ch.new and any_glob(ch.new, test_globs):
            git(wt, "checkout", head, "--", ch.new)
            out.append(ch.new)
    return out


def r1(repo, mb, head, adapter, test_globs, head_branch, agent_prefix, cmd, runner, project_dir="."):
    """R1 red-first: the tests this PR adds or changes, run against the base's production code (a worktree at the merge
    base with head's test-path files on top), must catch the change: at least one fails there. Tests that pass there
    pin existing behaviour (guards) and are fine. Commit order does not matter, so a later commit can fix an R1 fail.
    R4 runs the same tests at head. Returns (check, entries)."""
    if head_branch is None:
        return check("skipped", "no --head-branch: cannot tell an agent branch"), []
    if not head_branch.startswith(agent_prefix):
        return check("skipped", f"branch {head_branch} does not match the agent prefix {agent_prefix}"), []
    if not prod_changes(repo, mb, head, adapter, test_globs):
        return check("skipped", "no production file changed"), []
    forbidden = "a production change no test catches"
    tests = touched(repo, mb, head, adapter, test_globs)
    if not tests:
        # test-path files of another language (a python PTY smoke in a rust crate): R1 runs only this stack's tests and
        # cannot prove them red. A fail the agent can fix alone, with the route in the hint; not "no new test"
        other = sorted({ch.new for ch in changes(repo, mb, head)
                        if ch.new and any_glob(ch.new, test_globs) and adapter.classify(ch.new, test_globs) is None})
        if other:
            entries = [entry("R1", path, 0, f"other-stack:{path}", "agent-fixable", "fail",
                             f"test `{path}` does not count: R1 runs only {adapter.name} tests, so it cannot "
                             "prove this one fails without the change",
                             f"add a {adapter.name} test that fails without this PR's production change, for the "
                             "ticket's reason (keep the smoke too). Logic only a smoke reaches (a run loop, key "
                             "handling): move the decision into a pure fn and test that fn; R3 needs that test as well",
                             forbidden) for path in other]
            return check("fail", f"0 {adapter.name} tests changed; {len(other)} test file{'s' if len(other) > 1 else ''} "
                                 f"R1 cannot run ({adapter.name} stack)"), entries
        return check("fail", "no new or changed test"), [
            entry("R1", "", 0, "no-tests", "agent-fixable", "fail", "the PR adds or changes no test",
                  "add a test that fails without this PR's production change, for the ticket's reason", forbidden)]
    entries, red_count, compile_red, guards = [], 0, 0, []
    with worktree(repo, mb) as wt:
        overlay_tests(repo, wt, mb, head, test_globs)
        adapter.worktree_setup(repo, wt, project_dir)
        cmd = cmd or adapter.test_cmd_in(os.path.join(wt, project_dir))
        for path, name, line in tests:
            verdict, first = run_in(runner, adapter, cmd, wt, project_dir, path, name)
            if verdict == "env":
                return check("n/a", absent(cmd, "tests on the base's production code", first)), []
            if verdict == "fail":
                red_count += 1
            elif verdict == "build":
                compile_red += 1
                entries.append(entry("R1", path, line, f"compile-red:{name}", "agent-fixable", "confirm",
                                     f"compile-red: `{name}` does not build on the base's production code, counts as red",
                                     "reviewer confirms the build failure is the ticket's reason (a new API), not a typo",
                                     forbidden))
            elif verdict == "pass":
                guards.append(name)
            else:
                extra = no_manifest_hint(adapter, wt, project_dir) if verdict == "error" else ""
                entries.append(entry("R1", path, line, f"red-unproven:{name}", "agent-fixable", "fail",
                                     f"`{name}` cannot be proven red on the base's production code ({verdict}: {first})",
                                     "fix the test so it runs on the base's code too (setup, fixtures, names)" + extra,
                                     forbidden))
    if red_count + compile_red == 0 and not any(e["severity"] == "fail" for e in entries):
        shown = ", ".join(f"`{n}`" for n in guards[:5]) + (f" and {len(guards) - 5} more" if len(guards) > 5 else "")
        path, _, line = tests[0]
        entries.append(entry("R1", path, line, "no-red", "agent-fixable", "fail",
                             f"no new or changed test fails without this PR's production change: {shown} pass on "
                             "the base's code too",
                             "add or change a test so it fails on the base's code for the ticket's reason; tests that "
                             "pin existing behaviour can stay as guards",
                             forbidden))
    note = f"{red_count} of {len(tests)} new or changed test(s) fail on the base's production code"
    if compile_red:
        note += f"; {compile_red} compile-red"
    return check("fail" if any(e["severity"] == "fail" for e in entries) else "pass", note), entries


def r4(repo, mb, head, adapter, test_globs, cmd, runner, project_dir="."):
    """R4 determinism: each new or changed test runs TEST_RUNS times at head; any failing run is a fail. Returns (check, entries)."""
    tests = touched(repo, mb, head, adapter, test_globs)
    entries = unparseable(repo, mb, head, adapter, test_globs)
    if not tests:
        if entries:
            return check("fail", "a changed file does not parse"), entries
        return check("pass", "0 new or changed tests"), []
    with worktree(repo, head) as wt:
        adapter.worktree_setup(repo, wt, project_dir)
        cmd = cmd or adapter.test_cmd_in(os.path.join(wt, project_dir))
        for path, name, line in tests:
            verdicts = []
            for _ in range(TEST_RUNS):
                verdict, first = run_in(runner, adapter, cmd, wt, project_dir, path, name)
                if verdict == "env":
                    return check("n/a", absent(cmd, "new or changed tests", first)), []
                if verdict == "build":
                    entries.append(entry("R4", path, line, f"build:{name}", "agent-fixable", "fail",
                                         f"does not build at head: `{name}` cannot run",
                                         "fix the build: new or changed tests must run", "a test that does not build"))
                    return check("fail", "does not build at head"), entries
                if verdict == "error":
                    extra = no_manifest_hint(adapter, wt, project_dir)
                    entries.append(entry("R4", path, line, f"cannot-run:{name}", "agent-fixable", "fail",
                                         f"test `{name}` cannot run at head: {first}",
                                         "fix the test setup (manifest, flags); the toolchain did not reach a test result" + extra,
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
