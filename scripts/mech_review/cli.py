"""CLI: parse args, run the engine, print contract JSON, exit 0 (no fail entries) / 1 (any fail entry) / 2 (usage, git)."""
import argparse
import json
import re
import sys

from . import engine, merge
from .stack import ADAPTERS


HELP = """\
mechanical PR checks over base...head (merge-base diff). Prints the contract JSON.

checks (status in envelope: pass | fail | partial | n/a | skipped):
  R2  test-diff guard: removed test fn (a rename with the same asserts is not
      a removal); added #[ignore] or a cfg that disables it or its mod; should_panic added to an
      existing test (confirm); fewer asserts in a surviving test fn, or helper asserts per file;
      assert replaced in place, any kind (confirm); changed expected value (confirm); added
      #[allow]/#[expect] without a non-empty reason= or same-line comment; change under protected
      paths (needs-human).
      Test fns are keyed by mod-qualified name (m1::works). A test that loses asserts is exempt
      only up to the asserts gained by a helper it calls by name (call-site, each gain used once).
  R1  red-first (red subcommand): the first test(red) commit in base..head touches no production
      file; its new tests fail there (build failure = compile-red, confirm); they pass at head.
      Skipped unless --head-branch starts with --agent-prefix and a production file changed.
      Runs in a git worktree at the red commit; n/a when the toolchain is absent.
  R4  determinism (red subcommand): each new or changed #[test] runs 5x at head; any failing run
      is a fail. n/a when the toolchain is absent.
  R3  mutation on the diff (`mutants`): cargo-mutants `--in-diff`, run in a worktree at head, 120 s per mutant
      (`--mutant-timeout`), budget `--mutation-budget MIN` (default 10, per shard). MISSED in a production file
      -> fail (agent-fixable), one entry per mutant; TIMEOUT and UNVIABLE ignored. Budget hit with no MISSED ->
      partial (tested/total), not blocking. Tool not installed -> n/a (env). No production file -> skipped.
      `--shard K/N` runs one of N shards (K is 0-based, as cargo-mutants numbers them).
  `r2` runs R2. `red` runs R1 and R4. `all` runs R1, R2 and R4. `mutants` runs R3. A check a subcommand does not run
  is skipped with `not run by <subcommand>`.
  Test runner: the stack default (rust: `cargo test`), or --test-cmd. Env MECH_TEST_STUB=<exe>
  replaces the executable (arguments kept): the injectable runner for tests.

summary (one line, text format first line and envelope `summary`):
  `all pass <head sha>`: no entries and every check passed (never while a check is skipped or n/a).
  otherwise `<pass|fail> <head sha> (<F> fail, <C> confirm; ran: <checks>[; skipped: <checks>][; n/a: <checks>])`,
  e.g. `pass <sha> (0 fail, 1 confirm; ran: R2; skipped: R1 R3 R4)`.
  `pass` = no fail entries; `fail` = at least one fail entry; `n/a` = toolchain absent, not run.

envelope: ek (plugin version), base, head (full SHAs), checks, entries, summary.

exit: 0 no fail entries (confirm entries allowed), 1 any fail entry, 2 usage or git error.

Guard exceptions removed (#27): --pr-body is a usage error (exit 2). A fail stays fail until
  the code is fixed; a protected-path change is needs-human. Owner decides out of band.

test paths: a .rs file matching a --test-paths glob is test code; every assert in it (helpers too) counts.
  Other .rs files count asserts inside #[test] fns and #[cfg(test)] mods only, never production code.
  Globs: ** any depth, * one segment.
"""


class Removed(argparse.Action):
    """--pr-body tombstone: guard exceptions are gone (#27). Any use is a usage error."""

    def __call__(self, parser, namespace, values, option_string=None):
        parser.error("--pr-body removed: guard exceptions were removed (#27); a fail stays fail until the code is fixed")


def build_parser():
    p = argparse.ArgumentParser(prog="mech-review.py", description=HELP, formatter_class=argparse.RawDescriptionHelpFormatter,
                                epilog="example: python3 -I scripts/mech-review.py r2 --repo . --base main --head HEAD "
                                       "--stack rust --test-paths 'tests/**' --protected-paths '.github/**'")
    p.add_argument("check", choices=["r2", "red", "all", "mutants", "merge", "plan"],
                   help="r2: test-diff guard (R2); red: red-first and determinism (R1, R4); all: R1, R2, R4; "
                        "mutants: mutation on the diff (R3); merge: combine the mutants shard results (--shards, --envelope); "
                        "plan: does the mutants job run, and its shard matrix (--shards)")
    p.add_argument("--repo", default=".", help="git repo (default .)")
    p.add_argument("--base", required=True, help="base ref")
    p.add_argument("--head", required=True, help="head ref")
    p.add_argument("--stack", required=True, choices=sorted(ADAPTERS), help="language adapter")
    p.add_argument("--test-paths", action="append", default=[], metavar="GLOB", help="test file glob, repeatable")
    p.add_argument("--protected-paths", action="append", default=[], metavar="GLOB", help="protected file glob, repeatable")
    p.add_argument("--pr-body", nargs="?", action=Removed, help=argparse.SUPPRESS)
    p.add_argument("--format", choices=["json", "text"], default="json", help="json (contract, default) or text (summary + entries)")
    p.add_argument("--head-branch", metavar="NAME", help="head branch name (R1 needs it: CI passes github.head_ref)")
    p.add_argument("--agent-prefix", default="agent/", metavar="PREFIX", help="agent branch prefix for R1 (default agent/)")
    p.add_argument("--test-cmd", metavar="CMD", help="test command for R1/R4 (default: the stack's, rust: cargo test)")
    p.add_argument("--mutants-cmd", metavar="CMD", default="cargo mutants", help="mutation tool for R3 (default: cargo mutants)")
    p.add_argument("--mutation-budget", type=float, default=10.0, metavar="MIN",
                   help="R3 budget in minutes for this run (default 10); a budget hit is partial, not a failure")
    p.add_argument("--mutant-timeout", type=int, default=120, metavar="SEC",
                   help="R3 per-mutant timeout in seconds, cargo-mutants --timeout (default 120)")
    p.add_argument("--shard", metavar="K/N", help="R3 only: run shard K of N (0-based, as cargo-mutants numbers them)")
    p.add_argument("--shards", type=int, default=1, metavar="N", help="merge and plan: number of mutants shards")
    p.add_argument("--envelope", action="append", metavar="K=FILE",
                   help="merge only: result of shard K (0-based), repeatable; a missing shard fails R3 with a CI entry")
    return p


def render_text(env):
    lines = [env["summary"]]
    for e in env["entries"]:
        lines.append(f"{e['severity']} {e['id']} {e['file']}:{e['line']} {e['problem']}")
        lines.append(f"  hint: {e['hint']}")
        lines.append(f"  forbidden: {e['forbidden']}")
    return "\n".join(lines)


SHARD = re.compile(r"^(\d+)/(\d+)$")


def _plan(parser, args):
    """Print {run, count, shards}: whether the mutants job runs and its shard matrix. Exit 0 (2 on usage or git error)."""
    if args.shards < 1:
        parser.error("--shards N: want N >= 1")
    try:
        out = engine.plan(args.repo, args.base, args.head, args.stack, args.test_paths, args.shards)
    except engine.Die as e:
        print(f"mech-review: {e}", file=sys.stderr)
        return 2
    print(json.dumps(out))
    return 0


def _sha(repo, ref):
    """A full SHA is taken as is (the merge job has no checkout); any other ref is resolved in repo."""
    return ref if re.fullmatch(r"[0-9a-f]{40}", ref) else engine.resolve(repo, ref)


def _merge(parser, args):
    """Combine the mutants shard envelopes into one R3 envelope on stdout. Exit 1 on any fail entry."""
    n = args.shards
    if n < 1:
        parser.error("--shards N: want N >= 1")
    try:
        base = _sha(args.repo, args.base)
        head = _sha(args.repo, args.head)
    except engine.Die as e:
        print(f"mech-review: {e}", file=sys.stderr)
        return 2
    shards, reasons = {}, {}
    for item in args.envelope or []:
        k, sep, path = item.partition("=")
        if not sep or not k.isdigit() or int(k) >= n:
            parser.error(f"--envelope {item}: want K=FILE with 0 <= K < {n}")
        k = int(k)
        env = merge.load_envelope(path)
        if env is None:
            reasons[k] = "no usable result file"
        elif env["head"] != head:
            reasons[k] = f"result is for an older head, not {head}"
        else:
            shards[k] = env
    for k in range(n):
        shards.setdefault(k, None)
        reasons.setdefault(k, "no result file given")
    env = merge.combine_shards(base, head, n, shards, reasons)
    print(json.dumps(env, indent=2))
    return 1 if any(e["severity"] == "fail" for e in env["entries"]) else 0


def main(argv):
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.check == "merge":
        return _merge(parser, args)
    if args.check == "plan":
        return _plan(parser, args)
    if args.shard is not None:
        m = SHARD.match(args.shard)
        if args.check != "mutants":
            parser.error("--shard applies to the mutants check only")
        if not m or int(m.group(1)) >= int(m.group(2)) or int(m.group(2)) < 1:
            parser.error(f"--shard {args.shard}: want K/N with 0 <= K < N")
    try:
        env = engine.run(args.repo, args.base, args.head, args.stack, args.test_paths, args.protected_paths,
                         which=args.check, agent_prefix=args.agent_prefix, head_branch=args.head_branch,
                         test_cmd=args.test_cmd, mutants_cmd=args.mutants_cmd,
                         mutation_budget=args.mutation_budget, shard=args.shard, mutant_timeout=args.mutant_timeout)
    except engine.Die as e:
        print(f"mech-review: {e}", file=sys.stderr)
        return 2
    if args.format == "json":
        print(json.dumps(env, indent=2))
    else:
        print(render_text(env))
    return 1 if any(e["severity"] == "fail" for e in env["entries"]) else 0
