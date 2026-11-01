#!/bin/bash
# Structural test of the python toolchain in the reusable mech-review workflow (red-first and mutants jobs).
# Line-based parse like mech-review-workflow.test.sh (no PyYAML). The rust steps are checked by that test.
source "$(dirname "$0")/lib.sh"
python3 -I - "$ROOT" <<'PY'
import os
import re
import sys

ROOT = sys.argv[1]
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


def read(rel):
    with open(os.path.join(ROOT, rel)) as f:
        return f.read().splitlines()


def indent(line):
    return len(line) - len(line.lstrip(" "))


def meaningful(line):
    s = line.strip()
    return bool(s) and not s.startswith("#")


def block(lines, key, at=None):
    for n, line in enumerate(lines):
        if meaningful(line) and line.strip().startswith(key + ":") and (at is None or indent(line) == at):
            base = indent(line)
            out = []
            for later in lines[n + 1:]:
                if meaningful(later) and indent(later) <= base:
                    break
                out.append(later)
            return out
    return None


def step(lines, name):
    """Lines of the step `- name: <name>` up to the next `- name:`, stripped. [] if absent."""
    start = next((n for n, l in enumerate(lines) if l.strip() == f"- name: {name}"), None)
    if start is None:
        return []
    out = []
    for l in lines[start + 1:]:
        if l.strip().startswith("- name:"):
            break
        out.append(l.strip())
    return out


def value(lines, key):
    for l in lines:
        if l.strip().startswith(key + ":"):
            v = l.strip()[len(key) + 1:].strip()
            return v[1:-1] if len(v) >= 2 and v[0] == v[-1] == '"' else v
    return None


W = read(".github/workflows/mech-review.yml")
jobs = block(W, "jobs", 0) or []
inputs = block(block(block(W, "on", 0) or [], "workflow_call") or [], "inputs") or []
red = block(jobs, "red-first") or []
mut = block(jobs, "mutants") or []
plan = block(jobs, "plan") or []

stack_desc = " ".join(block(inputs, "stack") or [])
check("input: stack description names python", "python" in stack_desc and "rust" in stack_desc, stack_desc)
check("input: stack default still rust", value(block(inputs, "stack") or [], "default") == "rust")

for job_name, job in (("red-first", red), ("mutants", mut)):
    py = step(job, "Python toolchain")
    txt = "\n".join(py)
    check(f"{job_name}: a Python toolchain step exists", bool(py), str(py))
    check(f"{job_name}: python step runs only for the python stack", value(py, "if") == "inputs.stack == 'python'",
          str(value(py, "if")))
    check(f"{job_name}: python step uses no third-party action (runner python, venv)", not any(l.startswith("uses:") for l in py),
          str([l for l in py if l.startswith("uses:")]))
    check(f"{job_name}: python step creates a venv on the runner python", "python3 -m venv" in txt, txt)
    check(f"{job_name}: python step installs pytest pinned", re.search(r"pytest==\d+\.\d+\.\d+", txt) is not None, txt)
    check(f"{job_name}: python step installs the caller's requirements files",
          "requirements*.txt" in txt and "-r" in txt, txt)
    check(f"{job_name}: python step never installs the project itself (tests would run the head's copy, not the worktree)",
          not re.search(r"pip install (-e|--editable|\.|\.\[)", txt), txt)
    check(f"{job_name}: no system pip (PEP 668 image, venv only)",
          "--break-system-packages" not in txt and "sudo pip" not in txt, txt)
    check(f"{job_name}: python step puts the venv on PATH for later steps", "GITHUB_PATH" in txt, txt)
    check(f"{job_name}: python step fails loudly (set -e)", "set -eu" in txt or "set -e" in txt, txt)

mutmut_step = "\n".join(step(mut, "Python toolchain"))
check("mutants: mutmut installed pinned to 3.8.1", "mutmut==3.8.1" in mutmut_step, mutmut_step)
check("red-first: mutmut is not installed (R1/R4 run tests only)", "mutmut" not in "\n".join(step(red, "Python toolchain")))

cm = step(mut, "install cargo-mutants (pinned)")
check("mutants: cargo-mutants install only for the rust stack", "inputs.stack == 'rust'" in " ".join(cm)
      or any(l == "if: inputs.stack == 'rust'" for l in cm), str(cm))
check("mutants: cargo-mutants install still continues on error", any(l == "continue-on-error: true" for l in cm), str(cm))
check("red-first: the rust toolchain is still for the rust stack only",
      any(l == "if: inputs.stack == 'rust'" for l in step(red, "Rust toolchain")), str(step(red, "Rust toolchain")))

check("plan job has no toolchain step (git only)", not any("toolchain" in l.lower() for l in plan))
check("python steps: no PR code run outside the test and mutation jobs", "mech-review.py" not in "\n".join(step(red, "Python toolchain")))

sys.exit(1 if FAILS else 0)
PY
eq "$?" 0 "workflow: python toolchain steps per stack (red-first, mutants), mutmut pinned, no project install"

done_tests
