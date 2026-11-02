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
want_inputs = {"stack", "test-paths", "protected-paths", "agent-branch-prefix", "mutation-budget", "extra-apt-packages",
               "project-dir", "setup-command", "mutant-timeout", "rust-toolchain"}
check("reusable: exactly the 10 inputs", child_keys(inputs) == want_inputs, str(sorted(child_keys(inputs))))
check("reusable: stack defaults to rust", value(block(inputs, "stack") or [], "default") == "rust")
check("reusable: mutant-timeout defaults to empty (auto: no --timeout, baseline unlimited)",
      value(block(inputs, "mutant-timeout") or [], "default") == "", str(block(inputs, "mutant-timeout")))
check("reusable: rust-toolchain defaults to stable", value(block(inputs, "rust-toolchain") or [], "default") == "stable",
      str(block(inputs, "rust-toolchain")))

perm = block(W, "permissions", 0) or []
perm_map = {k: value(perm, k) for k in child_keys(perm)}
check("reusable: top permissions exactly contents read + pull-requests write",
      perm_map == {"contents": "read", "pull-requests": "write"}, str(perm_map))
check("reusable: no pull_request_target", "pull_request_target" not in text(W))

jobs = block(W, "jobs", 0) or []
job_perm_lines = [n for n, l in enumerate(W) if re.match(r"\s+permissions:", l)]
red_has_perm = any(l.strip() == "permissions:" for l in (block(jobs, "red-first") or []))
mut_job = block(jobs, "mutants") or []
mut_has_perm = any(l.strip() == "permissions:" for l in mut_job)
base_has_perm = any(l.strip() == "permissions:" for l in (block(jobs, "baseline") or []))
check("reusable: job-level permissions only on red-first, baseline and mutants (PR code jobs; guard, plan, report inherit top-level)",
      red_has_perm and mut_has_perm and base_has_perm and len(job_perm_lines) == 3, f"job-level permissions lines: {job_perm_lines}")
check("reusable: jobs are exactly guard + red-first + report + plan + baseline + mutants (#46)",
      child_keys(jobs) == {"guard", "red-first", "report", "plan", "baseline", "mutants"}, str(child_keys(jobs)))
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
check("report: downloads the guard, red-first, baseline and mutants artifacts (#46)",
      text(report).count("download-artifact@v4") == 4 and "mech-review-red-json" in text(report)
      and "mech-review-baseline-json" in text(report), text(report))
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
check("red-first: rust-toolchain passes toolchain from the rust-toolchain input (required when pinned by SHA)",
      any(l == "toolchain: ${{ inputs.rust-toolchain }}" for l in tc), str(tc))
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

# ---- R3 mutants: plan, shard matrix, merge ----
pl = block(jobs, "plan") or []
mu = block(jobs, "mutants") or []
pt = text(pl)
mt = text(mu)
check("plan: job present", bool(pl))
check("plan: runs mech-review.py plan", "mech-review.py" in pt and " plan" in pt, pt)
check("plan: caller checkout at PR head with full history",
      "github.event.pull_request.head.sha" in pt and re.search(r"fetch-depth:\s*0", pt) is not None)
check("plan: ek checkout at job.workflow_sha", re.search(r"ref:\s*\$\{\{\s*job\.workflow_sha\s*\}\}", pt) is not None)
check("plan: exposes the run output only (#46: the shard count comes from baseline)",
      re.search(rf"^\s+run:\s*\$\{{\{{\s*steps\.\w+\.outputs\.run\s*\}}\}}", pt, re.M) is not None
      and "count:" not in pt and "shards:" not in pt, pt)
check("plan: no language toolchain", re.search(r"setup-|toolchain|cargo|rustup", pt) is None)
check("plan: no --shards (no mutant count in git)", "--shards" not in pt, pt)

bl = block(jobs, "baseline") or []
bt = text(bl)
check("baseline: job present", bool(bl))
check("baseline: needs plan", (value(bl, "needs") or "").strip("[]") == "plan", str(value(bl, "needs")))
check("baseline: runs only when the plan says so", "needs.plan.outputs.run == 'true'" in (value(bl, "if") or ""),
      str(value(bl, "if")))
check("baseline: job-level permissions exactly contents read (it runs PR code for rust)",
      {k: value(block(bl, "permissions") or [], k) for k in child_keys(block(bl, "permissions") or [])} == {"contents": "read"},
      str(block(bl, "permissions")))
check("baseline: caller checkout at PR head with full history",
      "github.event.pull_request.head.sha" in bt and re.search(r"fetch-depth:\s*0", bt) is not None)
check("baseline: ek checkout at job.workflow_sha", re.search(r"ref:\s*\$\{\{\s*job\.workflow_sha\s*\}\}", bt) is not None)
check("baseline: runs mech-review.py baseline", "mech-review.py" in bt and " baseline" in bt, bt)
check("baseline: shard count from the shards setting (4)", "MUTATION_SHARDS" in bt or "--shards" in bt, bt)
check("baseline: budget from the mutation-budget input", "inputs.mutation-budget" in bt and "--mutation-budget" in bt, bt)
check("baseline: does not read mutant-timeout (a set value never caps the baseline)", "mutant-timeout" not in bt, bt)
check("baseline: outputs run, count, shards and timeout",
      all(re.search(rf"^\s+{k}:\s*\$\{{\{{\s*steps\.\w+\.outputs\.{k}\s*\}}\}}", bt, re.M)
          for k in ("run", "count", "shards", "timeout")), bt)
check("baseline: rust toolchain pinned to a full SHA, for the rust stack",
      "dtolnay/rust-toolchain@" in bt and "inputs.stack == 'rust'" in bt, bt)
check("baseline: cargo-mutants pinned to 27.1.0, install failure is not a stop", "cargo-mutants@27.1.0" in bt
      and "continue-on-error: true" in bt, bt)
check("baseline: uploads its JSON artifact", "mech-review-baseline-json" in bt and "upload-artifact" in bt, bt)
check("baseline: no pull_request_target", "pull_request_target" not in bt)

check("mutants: needs plan and baseline", {"plan", "baseline"} <= set(re.split(r"[\s,\[\]]+", (value(mu, "needs") or ""))),
      str(value(mu, "needs")))
check("mutants: runs only when the baseline says shards run (#46)", "needs.baseline.outputs.run == 'true'" in (value(mu, "if") or ""),
      str(value(mu, "if")))
strategy = block(mu, "strategy") or []
check("mutants: shard matrix from the baseline output", "fromJSON(needs.baseline.outputs.shards)" in text(strategy), text(strategy))
check("mutants: fail-fast off (one shard's failure does not cancel the others)", value(strategy, "fail-fast") == "false",
      str(value(strategy, "fail-fast")))
mperm = block(mu, "permissions") or []
check("mutants: job-level permissions exactly contents read (runs PR code)",
      {k: value(mperm, k) for k in child_keys(mperm)} == {"contents": "read"}, str({k: value(mperm, k) for k in child_keys(mperm)}))
check("mutants: no pull_request_target", "pull_request_target" not in mt)
check("mutants: caller checkout at PR head with full history",
      "github.event.pull_request.head.sha" in mt and re.search(r"fetch-depth:\s*0", mt) is not None)
check("mutants: ek checkout at job.workflow_sha", re.search(r"ref:\s*\$\{\{\s*job\.workflow_sha\s*\}\}", mt) is not None)


def step(lines, name):
    """Lines of the step `- name: <name>` (to the next `- name:`), stripped. [] if absent."""
    start = next((n for n, l in enumerate(lines) if l.strip() == f"- name: {name}" or l.strip().startswith(f"- name: {name} ")), None)
    if start is None:
        return []
    out = []
    for l in lines[start + 1:]:
        if l.strip().startswith("- name:"):
            break
        out.append(l.strip())
    return out


tcs = step(mu, "Rust toolchain")
tc_uses = next((l.split("uses:", 1)[1].split("#")[0].strip() for l in tcs if l.startswith("uses:")), "")
check("mutants: rust-toolchain pinned to a full 40-hex commit SHA",
      re.fullmatch(r"dtolnay/rust-toolchain@[0-9a-f]{40}", tc_uses) is not None, tc_uses)
check("mutants: rust-toolchain passes toolchain from the rust-toolchain input",
      "toolchain: ${{ inputs.rust-toolchain }}" in tcs, str(tcs))

ins = step(mu, "install cargo-mutants (pinned)")
ins_uses = next((l.split("uses:", 1)[1].split("#")[0].strip() for l in ins if l.startswith("uses:")), "")
check("mutants: cargo-mutants installed by a SHA-pinned action",
      re.fullmatch(r"taiki-e/install-action@[0-9a-f]{40}", ins_uses) is not None, ins_uses)
check("mutants: cargo-mutants pinned to 27.1.0", any(l == "tool: cargo-mutants@27.1.0" for l in ins), str(ins))
check("mutants: install failure does not stop the run (engine reports n/a env)",
      "continue-on-error: true" in ins, str(ins))

run_step = step(mu, "R3 mutation on the diff (shard)")
rs = "\n".join(run_step)
check("mutants: runs mech-review.py mutants", "mech-review.py" in rs and " mutants" in rs, rs)
check("mutants: shard flag from the matrix and the baseline's shard count",
      "matrix.shard" in rs and "needs.baseline.outputs.count" in rs, rs)
check("mutants: budget from the mutation-budget input", "inputs.mutation-budget" in mt and "--mutation-budget" in rs, rs)
check("mutants: mutant-timeout from the input, else the baseline's derived one (#46), via env, passed only when set",
      "MUTANT_TIMEOUT: ${{ inputs.mutant-timeout || needs.baseline.outputs.timeout }}" in mt
      and '--mutant-timeout "$MUTANT_TIMEOUT"' in rs and 'if [ -n "$MUTANT_TIMEOUT" ]' in rs, rs)
check("mutants: rc above 1 is no result (crash surfaces at report)", "rc -gt 1" in rs or "-gt 1" in rs, rs)
up = step(mu, "upload mutants result")
check("mutants: uploads its JSON artifact per shard", "mech-review-mutants-${{ matrix.shard }}" in "\n".join(up)
      and "upload-artifact" in mt and any(l == "if: always()" for l in up), str(up))

check("mutation-budget: used by the mutants job, not UNUSED",
      "UNUSED" not in " ".join(block(inputs, "mutation-budget") or []) and value(block(inputs, "mutation-budget") or [], "default") == "10",
      str(block(inputs, "mutation-budget")))

check("report: needs plan, baseline and mutants",
      {"plan", "baseline", "mutants"} <= set(re.split(r"[\s,\[\]]+", needs)), f"needs={needs!r}")
check("report: downloads the mutants shard artifacts (pattern)", "mech-review-mutants-*" in text(report), text(report))
check("report: merges the shards with the merge subcommand", "mech-review.py" in text(report) and " merge" in text(report), text(report))
check("report: mutants envelope only when the plan ran it, a crash is still reported",
      "mutants=" in text(report) and "PLAN_RESULT" in text(report) and "needs.plan.result" in text(report), text(report))

check("all third-party actions pinned to a full SHA (actions/* are GitHub's own, tag-pinned)",
      all(re.fullmatch(r"[0-9a-f]{40}", l.split("uses:", 1)[1].split("#")[0].strip().split("@", 1)[1])
          for l in W if l.strip().startswith("uses:") and not l.split("uses:", 1)[1].strip().startswith("actions/")),
      str([l for l in W if "uses:" in l]))

# ---- project-dir and setup-command: a crate in a subdirectory, a setup step (sysctl) before the tests ----
check("project-dir: default is the repo root", value(block(inputs, "project-dir") or [], "default") == ".",
      str(block(inputs, "project-dir")))
check("setup-command: default is empty", value(block(inputs, "setup-command") or [], "default") == "",
      str(block(inputs, "setup-command")))
docs_text = text(read("docs/mech-review-ci.md"))
check("docs: an Inputs row for every input", all(f"| `{k}` |" in docs_text for k in want_inputs),
      str(sorted(k for k in want_inputs if f"| `{k}` |" not in docs_text)))
check("project-dir and setup-command: never interpolated into a run: line",
      all(("inputs.setup-command" not in l or "if:" in l or "SETUP_COMMAND:" in l)
          and ("inputs.project-dir" not in l or "PROJECT_DIR:" in l) for l in W),
      str([l for l in W if "inputs.setup-command" in l or "inputs.project-dir" in l]))
for job_name, run_name in (("red-first", "R1 red-first, R4 determinism"), ("mutants", "R3 mutation on the diff (shard)")):
    jl = block(jobs, job_name) or []
    names = [l.strip()[len("- name: "):] for l in jl if l.strip().startswith("- name: ")]
    run_st = step(jl, run_name)
    check(f"{job_name}: passes --project-dir from the input via env",
          '--project-dir "$PROJECT_DIR"' in text(run_st) and "PROJECT_DIR: ${{ inputs.project-dir }}" in text(run_st),
          str(run_st))
    sc = step(jl, "setup command")
    check(f"{job_name}: setup-command step runs only when set", "if: inputs.setup-command != ''" in sc, str(sc))
    check(f"{job_name}: setup-command passed through env, run with bash, not interpolated",
          "SETUP_COMMAND: ${{ inputs.setup-command }}" in sc and "shell: bash" in sc
          and 'run: bash -c "$SETUP_COMMAND"' in sc and not any("${{" in l for l in sc if l.startswith("run:")), str(sc))
    order = [n for n in names if n in ("extra apt packages", "setup command", run_name)]
    check(f"{job_name}: setup-command after extra apt packages, before the tests",
          order == ["extra apt packages", "setup command", run_name], str(names))

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

# ---- #46 docs: the baseline runs once; a set mutant-timeout does not cap it ----
check("workflow text: a set mutant-timeout no longer caps the baseline", "also caps the baseline" not in text(W),
      [l for l in W if "caps the baseline" in l])
check("docs: the baseline job is named in the jobs list", "`baseline`" in docs_text, "")
check("docs: a set mutant-timeout does not cap the baseline", "also caps the baseline" not in docs_text, "")

print("")
sys.exit(1 if FAILS else 0)
PY
