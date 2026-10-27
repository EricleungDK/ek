#!/bin/bash
# Structural test of the mech-review reusable workflow and ek's self caller.
# Stdlib line-based parse (no PyYAML): top-level blocks, child keys, scalar values.
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
    path = os.path.join(ROOT, rel)
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return f.read().splitlines()


def indent(line):
    return len(line) - len(line.lstrip(" "))


def meaningful(line):
    s = line.strip()
    return bool(s) and not s.startswith("#")


def block(lines, key, at=None):
    """Raw lines under the first mapping key `key` (optionally at indent `at`). None if absent."""
    if lines is None:
        return None
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


def child_lines(blk):
    lines = [l for l in (blk or []) if meaningful(l)]
    if not lines:
        return []
    base = min(indent(l) for l in lines)
    return [l for l in lines if indent(l) == base]


def child_keys(blk):
    return {l.strip().split(":")[0] for l in child_lines(blk) if not l.strip().startswith("-")}


def value(blk, key):
    for l in child_lines(blk):
        if l.strip().startswith(key + ":"):
            return l.strip()[len(key) + 1:].strip().strip("'\"")
    return None


def text(lines):
    return "\n".join(lines or [])


# ---- reusable workflow ----
RW = ".github/workflows/mech-review.yml"
W = read(RW)
check("reusable: file exists", W is not None, RW)
W = W or []

on = block(W, "on", 0) or []
check("reusable: on is workflow_call only", child_keys(on) == {"workflow_call"}, str(child_keys(on)))
wc = block(on, "workflow_call") or []
inputs = block(wc, "inputs") or []
want_inputs = {"stack", "test-paths", "protected-paths", "agent-branch-prefix", "mutation-budget", "extra-apt-packages"}
check("reusable: exactly the 6 inputs", child_keys(inputs) == want_inputs, str(sorted(child_keys(inputs))))
check("reusable: stack defaults to rust", value(block(inputs, "stack") or [], "default") == "rust")

perm = block(W, "permissions", 0) or []
perm_map = {k: value(perm, k) for k in child_keys(perm)}
check("reusable: top permissions exactly contents read + pull-requests write",
      perm_map == {"contents": "read", "pull-requests": "write"}, str(perm_map))
check("reusable: no job-level permissions block",
      not any(re.match(r"\s+permissions:", l) for l in W), "a job-level permissions key was found")
check("reusable: no pull_request_target", "pull_request_target" not in text(W))

jobs = block(W, "jobs", 0) or []
check("reusable: jobs are exactly guard + report", child_keys(jobs) == {"guard", "report"}, str(child_keys(jobs)))
guard = block(jobs, "guard") or []
report = block(jobs, "report") or []

needs = (value(report, "needs") or "").strip("[]")
check("reusable: report needs guard", "guard" in re.split(r"[\s,]+", needs), f"needs={needs!r}")
check("reusable: report runs even if guard fails", "always()" in (value(report, "if") or ""),
      f"if={value(report, 'if')!r}")

gt = text(guard)
check("guard: checks out ek at job.workflow_sha",
      re.search(r"ref:\s*\$\{\{\s*job\.workflow_sha\s*\}\}", gt) is not None)
check("guard: ek repo from job.workflow_repository", "job.workflow_repository" in gt)
check("guard: no language toolchain (no setup-*, toolchain, cargo, rustup)",
      re.search(r"setup-|toolchain|cargo|rustup", gt) is None)
check("guard: runs mech-review.py r2", "mech-review.py" in gt and " r2" in gt)
check("guard: uploads the JSON artifact", "upload-artifact" in gt)
check("report: downloads the JSON artifact", "download-artifact" in text(report))
check("report: posts via mech-comment.py", "mech-comment.py" in text(report))

# ---- ek's own caller ----
SW = ".github/workflows/mech-review-self.yml"
S = read(SW)
check("self: file exists", S is not None, SW)
S = S or []
son = block(S, "on", 0) or []
check("self: on pull_request", "pull_request" in child_keys(son), str(child_keys(son)))
check("self: no pull_request_target", "pull_request_target" not in child_keys(son))
sperm = block(S, "permissions", 0) or []
sperm_map = {k: value(sperm, k) for k in child_keys(sperm)}
check("self: permissions exactly contents read + pull-requests write",
      sperm_map == {"contents": "read", "pull-requests": "write"}, str(sperm_map))
sjobs = block(S, "jobs", 0) or []
local = [k for k in child_keys(sjobs) if value(block(sjobs, k) or [], "uses") == "./.github/workflows/mech-review.yml"]
check("self: exactly one job calls the local reusable workflow", len(local) == 1, str(local))
if local:
    w = block(block(sjobs, local[0]) or [], "with") or []
    check("self: stack rust", value(w, "stack") == "rust", str(value(w, "stack")))
    check("self: test-paths tests/**", value(w, "test-paths") == "tests/**", str(value(w, "test-paths")))
    check("self: protected-paths .github/**", value(w, "protected-paths") == ".github/**",
          str(value(w, "protected-paths")))

print("")
sys.exit(1 if FAILS else 0)
PY
