"""CLI: parse args, run the engine, print contract JSON, exit 0 (all pass) / 1 (any fail entry) / 2 (usage, git)."""
import argparse
import json
import sys

from . import engine
from .stack import ADAPTERS


def build_parser():
    p = argparse.ArgumentParser(prog="mech-review.py", description="mechanical PR checks; prints contract JSON")
    p.add_argument("check", choices=["r2", "all"], help="r2: test-diff guard; all: every implemented check")
    p.add_argument("--repo", default=".", help="git repo (default .)")
    p.add_argument("--base", required=True, help="base ref")
    p.add_argument("--head", required=True, help="head ref")
    p.add_argument("--stack", required=True, choices=sorted(ADAPTERS), help="language adapter")
    p.add_argument("--test-paths", action="append", default=[], metavar="GLOB", help="test file glob, repeatable")
    p.add_argument("--protected-paths", action="append", default=[], metavar="GLOB", help="protected file glob, repeatable")
    p.add_argument("--pr-body", metavar="FILE", help="PR body file; its Guard exceptions section downgrades fails")
    return p


def read_body(path):
    if path is None:
        return None
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        raise engine.Die(f"cannot read --pr-body {path}: {e.strerror}")


def main(argv):
    args = build_parser().parse_args(argv)
    try:
        body = read_body(args.pr_body)
        env = engine.run(args.repo, args.base, args.head, args.stack, args.test_paths, args.protected_paths, body)
    except engine.Die as e:
        print(f"mech-review: {e}", file=sys.stderr)
        return 2
    print(json.dumps(env, indent=2))
    return 1 if any(e["severity"] == "fail" for e in env["entries"]) else 0
