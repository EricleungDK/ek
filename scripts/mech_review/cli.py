"""CLI: parse args, run the engine, print contract JSON, exit 0 (all pass) / 1 (any fail entry) / 2 (usage, git)."""
import argparse
import json
import sys

from . import engine
from .stack import ADAPTERS


HELP = """\
mechanical PR checks over base...head (merge-base diff). Prints the contract JSON.

checks (status in envelope: pass | fail | partial | n/a | skipped):
  R2  test-diff guard (implemented): removed test fn; added #[ignore]; fewer asserts
      in a changed test file; added #[allow]/#[expect] without reason= or same-line
      comment; changed expected value (confirm); change under protected paths (needs-human)
  R1, R3, R4: not implemented yet, always skipped.
  `r2` and `all` run the same implemented checks.

entry: id, check, class (agent-fixable | needs-human | env), severity (fail | confirm),
  file, line (0 = file-level), problem, hint, forbidden.
  id = <check>-<first 8 hex of sha1(check + file + key)>; key = test fn name or rule
  (e.g. dead_code, assert-count, protected-path). Never depends on line numbers.

envelope: ek (plugin version), base, head (full SHAs), checks, entries, summary.
  summary is `all pass <head sha>` when there are no entries.

exit: 0 no fail entries (confirm entries allowed), 1 any fail entry, 2 usage or git error.

Guard exceptions: a PR body (--pr-body) with a heading 'Guard exceptions' listing
  `<id>: <reason>` lines downgrades that id's fail (class agent-fixable only) to confirm.
  needs-human entries are never downgraded. Reason needs at least 3 letters beside the id.

test paths: a .rs file matching a --test-paths glob is a test file; its assert count covers the
  whole file. Other .rs files count only asserts inside #[test] fns. Globs: ** any depth, * one segment.
"""


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
    p.add_argument("--pr-body", metavar="FILE", help="PR body file; its Guard exceptions section downgrades fails")
    p.add_argument("--format", choices=["json", "text"], default="json", help="json (contract, default) or text (summary + entries)")
    return p


def read_body(path):
    if path is None:
        return None
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        raise engine.Die(f"cannot read --pr-body {path}: {e.strerror}")


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
        body = read_body(args.pr_body)
        env = engine.run(args.repo, args.base, args.head, args.stack, args.test_paths, args.protected_paths, body)
    except engine.Die as e:
        print(f"mech-review: {e}", file=sys.stderr)
        return 2
    if args.format == "json":
        print(json.dumps(env, indent=2))
    else:
        print(render_text(env))
    return 1 if any(e["severity"] == "fail" for e in env["entries"]) else 0
