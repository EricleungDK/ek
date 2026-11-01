#!/bin/bash
# Structural test of the ts toolchain in the reusable mech-review workflow (red-first and mutants jobs): setup-node
# pinned to a SHA, a lockfile-aware install in the project dir, Stryker pinned and isolated, values through env.
# Line-based parse like mech-python-workflow.test.sh (no PyYAML).
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
check("input: stack description names ts", "ts" in stack_desc, stack_desc)
check("input: stack default still rust", value(block(inputs, "stack") or [], "default") == "rust")

SETUP = re.compile(r"^uses: actions/setup-node@([0-9a-f]{40})\b")
for job_name, job in (("red-first", red), ("mutants", mut)):
    ts_setup = [l for l in job if SETUP.match(l.strip())]
    check(f"{job_name}: setup-node is pinned to a full SHA", len(ts_setup) >= 1, str(ts_setup))
    tc = step(job, "TypeScript toolchain")
    check(f"{job_name}: a TypeScript toolchain step exists", bool(tc) or any("setup-node" in l for l in job),
          str(tc))
    check(f"{job_name}: setup-node runs only for the ts stack",
          any(l.strip() == "if: inputs.stack == 'ts'" for l in job), "")
    install = step(job, "TypeScript dependencies")
    txt = "\n".join(install)
    check(f"{job_name}: lockfile-aware install step exists", bool(install), str(install))
    check(f"{job_name}: install uses npm ci for package-lock.json", "npm ci" in txt and "package-lock.json" in txt, txt)
    check(f"{job_name}: install uses the repo's pnpm or yarn for their lockfiles",
          "pnpm-lock.yaml" in txt and "pnpm@" in txt and "yarn.lock" in txt and "yarn@" in txt, txt)
    check(f"{job_name}: a missing lockfile is a hard stop (no unpinned install)",
          "no lockfile" in txt and "exit 2" in txt, txt)
    check(f"{job_name}: install runs in caller/<project-dir>", 'caller/$PROJECT_DIR' in txt, txt)
    check(f"{job_name}: project-dir guarded before use", "case \"$PROJECT_DIR\"" in txt and "exit 2" in txt, txt)
    check(f"{job_name}: install step has no third-party action", not any(l.startswith("uses:") for l in install), txt)
    check(f"{job_name}: project-dir reaches the script through env, never inline in run",
          "PROJECT_DIR: ${{ inputs.project-dir }}" in txt
          and not any("${{" in l for l in install if not l.startswith(("PROJECT_DIR:", "- name:", "if:", "env:", "shell:"))),
          txt)

stryker = step(mut, "Stryker (pinned)")
stxt = "\n".join(stryker)
check("mutants: a Stryker install step exists", bool(stryker), str(stryker))
check("mutants: Stryker core pinned to 10.0.0", "@stryker-mutator/core@10.0.0" in stxt, stxt)
check("mutants: Stryker is installed into its own prefix, not the repo's node_modules",
      "--prefix" in stxt and "RUNNER_TEMP" in stxt, stxt)
check("mutants: Stryker install failure is not a stop (the engine says n/a)",
      any(l == "continue-on-error: true" for l in stryker), str(stryker))
check("mutants: Stryker install only for the ts stack", any(l == "if: inputs.stack == 'ts'" for l in stryker), str(stryker))
check("mutants: the Stryker binary is handed to the engine (--mutants-cmd)",
      "--mutants-cmd" in "\n".join(step(mut, "R3 mutation on the diff (shard)")), "")
check("red-first: Stryker is not installed (R1/R4 run tests only)", "Stryker" not in "\n".join(red))

for job_name, job in (("red-first", red), ("mutants", mut)):
    check(f"{job_name}: job permissions are contents read only",
          any(l.strip() == "contents: read" for l in block(job, "permissions") or []), str(block(job, "permissions")))

all_uses = [l.strip() for l in W if l.strip().startswith("uses:")]
for u in all_uses:
    m = re.match(r"uses: ([^@\s]+)@(\S+)", u)
    repo = m.group(1) if m else ""
    ref = m.group(2) if m else ""
    if repo in ("actions/checkout", "actions/upload-artifact", "actions/download-artifact"):
        continue
    check(f"third-party action pinned to a full SHA: {repo}", re.fullmatch(r"[0-9a-f]{40}", ref or "") is not None, u)

sys.exit(1 if FAILS else 0)
PY
eq "$?" 0 "workflow: ts toolchain steps (setup-node SHA, lockfile install, Stryker isolated and pinned, env values)"

done_tests
