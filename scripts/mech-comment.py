#!/usr/bin/env python3
"""mech-review report step: render the guard JSON, post or edit the sticky PR comment, set the exit code.

usage: python3 -I scripts/mech-comment.py --pr N [--envelope FILE] [--head SHA] [--reason TEXT]
env: GITHUB_TOKEN, GITHUB_REPOSITORY (owner/repo), GITHUB_API_URL (default https://api.github.com),
     GITHUB_STEP_SUMMARY (optional: rendered comment is also appended there).
exit: 0 no fail entries; 1 any fail entry; 2 usage; 3 GitHub API error;
      4 no usable result (a crash comment is posted in place of the result).
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from mech_review import comment as C  # noqa: E402


def load(path):
    """The envelope dict, or None if missing, unreadable or not an envelope."""
    if not path:
        return None
    try:
        with open(path) as fh:
            env = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(env, dict) or not all(k in env for k in ("head", "summary", "entries")):
        return None
    return env


def main(argv):
    ap = argparse.ArgumentParser(prog="mech-comment.py")
    ap.add_argument("--pr", type=int, required=True, help="pull request number")
    ap.add_argument("--envelope", help="guard JSON (mech-review.py r2 output)")
    ap.add_argument("--head", help="head sha, used for the crash comment")
    ap.add_argument("--reason", default="mech-review produced no JSON", help="crash reason")
    args = ap.parse_args(argv)

    token = os.environ.get("GITHUB_TOKEN")
    repo = os.environ.get("GITHUB_REPOSITORY")
    if not token:
        print("mech-comment: GITHUB_TOKEN not set", file=sys.stderr)
        return 2
    if not repo:
        print("mech-comment: GITHUB_REPOSITORY not set", file=sys.stderr)
        return 2
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")

    env = load(args.envelope)
    if env is None:
        if not args.head:
            print("mech-comment: no usable envelope and --head not given", file=sys.stderr)
            return 2
        body, rc = C.render_crash(args.head, args.reason), 4
        print(f"mech-comment: no usable result: {args.reason}", file=sys.stderr)
    else:
        body, rc = C.render(env), C.exit_code(env)

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as fh:
            fh.write(body)

    try:
        action, cid = C.upsert(C.http_call(token), api, repo, args.pr, body)
    except C.ApiError as e:
        print(f"mech-comment: {e}", file=sys.stderr)
        return 3
    print(f"mech-comment: {action} comment {cid}", file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
