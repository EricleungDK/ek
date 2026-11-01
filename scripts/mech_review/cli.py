"""CLI: parse args, run the engine, print contract JSON, exit 0 (no fail entries) / 1 (any fail entry) / 2 (usage, git)."""
import argparse
import json
import sys

from . import engine
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
  R3  mutation: not implemented, always skipped.
  `r2` runs R2. `red` runs R1 and R4. `all` runs R1, R2 and R4. A check a subcommand does not run
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
    p.add_argument("check", choices=["r2", "red", "all"],
                   help="r2: test-diff guard (R2); red: red-first and determinism (R1, R4); all: R1, R2, R4")
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
    return p


def render_text(env):
    lines = [env["summary"]]
    for e in env["entries"]:
        lines.append(f"{e['severity']} {e['id']} {e['file']}:{e['line']} {e['problem']}")
        lines.append(f"  hint: {e['hint']}")
        lines.append(f"  forbidden: {e['forbidden']}")
    return "\n".join(lines)


def main(argv):
    args = build_parser().parse_args(argv)
    try:
        env = engine.run(args.repo, args.base, args.head, args.stack, args.test_paths, args.protected_paths,
                         which=args.check, agent_prefix=args.agent_prefix, head_branch=args.head_branch,
                         test_cmd=args.test_cmd)
    except engine.Die as e:
        print(f"mech-review: {e}", file=sys.stderr)
        return 2
    if args.format == "json":
        print(json.dumps(env, indent=2))
    else:
        print(render_text(env))
    return 1 if any(e["severity"] == "fail" for e in env["entries"]) else 0
