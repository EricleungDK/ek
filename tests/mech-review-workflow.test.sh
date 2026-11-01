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
check("reusable: no pull_request_target", "pull_request_target" not in text(W))

jobs = block(W, "jobs", 0) or []
job_perm_lines = [n for n, l in enumerate(W) if re.match(r"\s+permissions:", l)]
red_has_perm = any(l.strip() == "permissions:" for l in (block(jobs, "red-first") or []))
check("reusable: job-level permissions only on red-first (guard and report inherit top-level)",
      red_has_perm and len(job_perm_lines) == 1, f"job-level permissions lines: {job_perm_lines}")
check("reusable: jobs are exactly guard + red-first + report", child_keys(jobs) == {"guard", "red-first", "report"},
      str(child_keys(jobs)))
guard = block(jobs, "guard") or []
red = block(jobs, "red-first") or []
report = block(jobs, "report") or []

needs = (value(report, "needs") or "").strip("[]")
check("reusable: report needs guard", "guard" in re.split(r"[\s,]+", needs), f"needs={needs!r}")
check("reusable: report needs red-first", "red-first" in re.split(r"[\s,]+", needs), f"needs={needs!r}")
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
check("guard: artifact overwrites on re-run", re.search(r"overwrite:\s*true", gt) is not None)
check("report: downloads the JSON artifact", "download-artifact" in text(report))
check("report: posts via mech-comment.py", "mech-comment.py" in text(report))
check("report: downloads both the guard and the red-first artifacts",
      text(report).count("download-artifact@v4") == 2 and "mech-review-red-json" in text(report),
      text(report))
check("report: named envelopes, guard as r2 and red-first as red",
      "--envelope r2=" in text(report) and "--envelope red=" in text(report), text(report))

rt = text(red)
check("red-first: checks out ek at job.workflow_sha",
      re.search(r"ref:\s*\$\{\{\s*job\.workflow_sha\s*\}\}", rt) is not None)
check("red-first: ek repo from job.workflow_repository", "job.workflow_repository" in rt)
check("red-first: caller checkout with full history (base..head needs it)",
      re.search(r"fetch-depth:\s*0", rt) is not None)
check("red-first: runs mech-review.py red", "mech-review.py" in rt and " red" in rt)
check("red-first: head branch from github.head_ref", "github.head_ref" in rt)
check("red-first: agent prefix from the agent-branch-prefix input", "inputs.agent-branch-prefix" in rt)
check("red-first: toolchain set up for the rust stack", "rust-toolchain" in rt and "inputs.stack == 'rust'" in rt)
# the step is a list item: its lines run from "- name: Rust toolchain" to the next "- name:"
_i = next((n for n, l in enumerate(red) if l.strip() == "- name: Rust toolchain"), None)
tc = []
if _i is not None:
    for l in red[_i + 1:]:
        if l.strip().startswith("- name:"):
            break
        tc.append(l)
tc = [l.strip() for l in tc]
uses_line = next((l.split("uses:", 1)[1].split("#")[0].strip() for l in tc if l.startswith("uses:")), "")
check("red-first: rust-toolchain pinned to a full 40-hex commit SHA",
      re.fullmatch(r"dtolnay/rust-toolchain@[0-9a-f]{40}", uses_line) is not None, uses_line)
check("red-first: rust-toolchain passes toolchain: stable (required when pinned by SHA)",
      any(l == "toolchain: stable" for l in tc), str(tc))
check("red-first: honours extra-apt-packages", "inputs.extra-apt-packages" in rt and "apt-get" in rt)
check("red-first: uploads its JSON artifact", "mech-review-red-json" in rt and "upload-artifact" in rt)
red_perm = block(red, "permissions") or []
check("red-first: job-level permissions exactly contents read",
      {k: value(red_perm, k) for k in child_keys(red_perm)} == {"contents": "read"},
      str({k: value(red_perm, k) for k in child_keys(red_perm)}))
check("red-first: no pull_request_target", "pull_request_target" not in rt)
check("inputs: agent-branch-prefix is used now, not UNUSED",
      "UNUSED" not in " ".join(block(inputs, "agent-branch-prefix") or []), str(block(inputs, "agent-branch-prefix")))
check("inputs: extra-apt-packages is used now, not UNUSED",
      "UNUSED" not in " ".join(block(inputs, "extra-apt-packages") or []), str(block(inputs, "extra-apt-packages")))

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
