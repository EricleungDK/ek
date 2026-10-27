"""CLI: parse args, run the engine, print contract JSON, exit 0 (no fail entries) / 1 (any fail entry) / 2 (usage, git)."""
import argparse
import json
import sys

from . import engine
from .stack import ADAPTERS


HELP = """\
mechanical PR checks over base...head (merge-base diff). Prints the contract JSON.

checks (status in envelope: pass | fail | partial | n/a | skipped):
  R2  test-diff guard (implemented): removed test fn; added #[ignore]; fewer asserts
      in a surviving test fn (per fn name) or in helpers outside test fns (per file);
      assert replaced in place (confirm); changed expected value (confirm); added
      #[allow]/#[expect] without reason= or same-line comment; change under protected
      paths (needs-human)
  R1, R3, R4: not implemented yet, always skipped.
  `r2` and `all` run the same implemented checks.

entry: id, check, class (agent-fixable | needs-human | env), severity (fail | confirm),
  file, line (0 = file-level), problem, hint, forbidden.
  id = <check>-<first 8 hex of sha1(check + file + key)>; key = test fn name or rule
  (e.g. ignore:<fn>, assert-count:<fn>, assert-count = helpers of a file). Never depends on line numbers.

summary (one line, text format first line and envelope `summary`):
  `all pass <head sha>`: no entries and every check passed (never while a check is skipped).
  otherwise `<pass|fail> <head sha> (<F> fail, <C> confirm; ran: <checks>[; skipped: <checks>])`,
  e.g. `pass <sha> (0 fail, 1 confirm; ran: R2; skipped: R1 R3 R4)`.
  `pass` = no fail entries; `fail` = at least one fail entry.

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
    p.add_argument("check", choices=["r2", "all"], help="r2: test-diff guard; all: every implemented check")
    p.add_argument("--repo", default=".", help="git repo (default .)")
    p.add_argument("--base", required=True, help="base ref")
    p.add_argument("--head", required=True, help="head ref")
    p.add_argument("--stack", required=True, choices=sorted(ADAPTERS), help="language adapter")
    p.add_argument("--test-paths", action="append", default=[], metavar="GLOB", help="test file glob, repeatable")
    p.add_argument("--protected-paths", action="append", default=[], metavar="GLOB", help="protected file glob, repeatable")
    p.add_argument("--pr-body", nargs="?", action=Removed, help=argparse.SUPPRESS)
    p.add_argument("--format", choices=["json", "text"], default="json", help="json (contract, default) or text (summary + entries)")
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
        env = engine.run(args.repo, args.base, args.head, args.stack, args.test_paths, args.protected_paths)
    except engine.Die as e:
        print(f"mech-review: {e}", file=sys.stderr)
        return 2
    if args.format == "json":
        print(json.dumps(env, indent=2))
    else:
        print(render_text(env))
    return 1 if any(e["severity"] == "fail" for e in env["entries"]) else 0
