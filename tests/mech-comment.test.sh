#!/bin/bash
# Comment poster: render (pure), find-or-edit with injectable transport (offline fake),
# and the CLI against a local HTTP server standing in for the GitHub API.
source "$(dirname "$0")/lib.sh"
python3 -I - "$ROOT" <<'PY'
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

ROOT = sys.argv[1]
sys.path.insert(0, os.path.join(ROOT, "scripts"))
POSTER = os.path.join(ROOT, "scripts", "mech-comment.py")
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


from mech_review import comment as C  # noqa: E402

SHA = "a" * 40
BASE = "b" * 40
REPO = "o/r"
API = "https://api.github.com"


def entry(sev="fail", cls="agent-fixable", eid="R2-deadbeef", file="tests/a.rs", line=7,
          problem="removed test fn b", forbidden="deleting tests", check_name="R2"):
    return {"id": eid, "check": check_name, "class": cls, "severity": sev, "file": file, "line": line,
            "problem": problem, "hint": "restore it", "forbidden": forbidden}


def env(entries=(), summary=None):
    fails = sum(1 for e in entries if e["severity"] == "fail")
    confirms = sum(1 for e in entries if e["severity"] == "confirm")
    if summary is None:
        status = "fail" if fails else "pass"
        summary = f"{status} {SHA} ({fails} fail, {confirms} confirm; ran: R2; skipped: R1 R3 R4)"
    return {"ek": "0.1.1", "base": BASE, "head": SHA,
            "checks": {"R2": {"status": "fail" if fails else "pass", "note": ""}},
            "entries": list(entries), "summary": summary}


def json_block(body):
    m = re.search(r"^(`{3,})json\n(.*?)\n\1$", body, re.S | re.M)
    return json.loads(m.group(2)) if m else None


class Fake:
    """Offline transport: GET pages of comments, POST/PATCH recorded."""

    def __init__(self, pages=None):
        self.pages = pages or {}
        self.calls = []

    def __call__(self, method, url, payload=None):
        self.calls.append((method, url, payload))
        if method == "GET":
            page = int(parse_qs(urlparse(url).query).get("page", ["1"])[0])
            return self.pages.get(page, [])
        if method == "PATCH":
            return {"id": int(url.rsplit("/", 1)[1]), "body": payload["body"]}
        return {"id": 999, "body": payload["body"]}


def methods(fake):
    return [m for m, _, _ in fake.calls]


# ---- render (pure) ----
e1 = env([entry()])
b = C.render(e1)
check("render: marker is the first line", b.splitlines()[0] == C.MARKER, b[:80])
check("render: summary line verbatim", e1["summary"] in b)
check("render: head sha shown", SHA in b)
check("render: entry row id | severity | file:line | problem | forbidden",
      "| R2-deadbeef | fail | tests/a.rs:7 | removed test fn b | deleting tests |" in b, b)
check("render: json block round-trips the envelope", json_block(b) == e1, str(json_block(b)))

b = C.render(env([entry(problem="a|b")]))
check("render: pipe escaped inside a table cell", "a\\|b" in b, b)

b = C.render(env([], summary=f"pass {SHA} (0 fail, 0 confirm; ran: R2; skipped: R1 R3 R4)"))
check("render: no entries says so", "No entries" in b, b)
check("render: no table when no entries", not re.search(r"^\| id ", b, re.M), b)
check("render: no entries still has json block", json_block(b) == env([], summary=f"pass {SHA} (0 fail, 0 confirm; ran: R2; skipped: R1 R3 R4)"))

fence = env([entry(problem="uses ``` fences")])
b = C.render(fence)
check("render: backticks in content keep json fence intact", json_block(b) == fence, b)

big = env([entry(eid=f"R2-{i:08x}", line=i, problem="x" * 300) for i in range(2000)])
b = C.render(big)
check("render: oversize body stays under 65536", len(b) <= 65536, str(len(b)))
check("render: oversize omits json block with note", json_block(b) is None and "JSON omitted" in b)
check("render: oversize table truncated with count", "2000" in b and "showing" in b, b[:400])

long_cell = env([entry(problem="y" * 500)])
b = C.render(long_cell)
row = next(l for l in b.splitlines() if l.startswith("| R2-deadbeef"))
check("render: long table cell truncated in the table row", "…" in row and "y" * 500 not in row and len(row) < 400, row)
check("render: JSON block keeps the full problem", json_block(b) == long_cell)

# ---- crash render ----
b = C.render_crash(SHA, "guard produced no JSON")
check("crash: marker is the first line", b.splitlines()[0] == C.MARKER)
check("crash: names head sha and reason", SHA in b and "guard produced no JSON" in b, b)
check("crash: no json block", json_block(b) is None)

# ---- exit code ----
check("exit: fail entry -> 1", C.exit_code(env([entry()])) == 1)
check("exit: confirm only -> 0", C.exit_code(env([entry(sev="confirm")])) == 0)
check("exit: no entries -> 0", C.exit_code(env([])) == 0)
check("exit: needs-human with severity fail -> 1",
      C.exit_code(env([entry(cls="needs-human", eid="R2-aaaaaaaa", file=".github/x.yml", line=0,
                             problem="protected path changed")])) == 1)

# ---- find / upsert (fake transport, offline) ----
f = Fake({1: [{"id": 1, "body": "unrelated"}]})
action, cid = C.upsert(f, API, REPO, 5, C.MARKER + "\nnew")
check("upsert: no marker comment -> created", action == "created", str(action))
check("upsert: POST to issue comments", ("POST", f"{API}/repos/o/r/issues/5/comments") in [(m, u) for m, u, _ in f.calls])
check("upsert: POST carries the body", f.calls[-1][2] == {"body": C.MARKER + "\nnew"})
check("upsert: single page not re-requested", methods(f).count("GET") == 1, str(methods(f)))

f = Fake({1: [{"id": i, "body": "unrelated"} for i in range(1, 101)],
          2: [{"id": 77, "body": C.MARKER + "\nold"}]})
action, cid = C.upsert(f, API, REPO, 5, C.MARKER + "\nnew")
check("upsert: paginates to find marker comment on page 2", action == "updated" and cid == 77, f"{action} {cid}")
check("upsert: PATCH the existing comment id",
      ("PATCH", f"{API}/repos/o/r/issues/comments/77") in [(m, u) for m, u, _ in f.calls])
check("upsert: no POST when marker comment exists", "POST" not in methods(f), str(methods(f)))
check("upsert: GET pages 1 and 2 only", methods(f).count("GET") == 2, str(methods(f)))

f = Fake({1: [{"id": i, "body": "unrelated"} for i in range(1, 101)], 2: []})
action, cid = C.upsert(f, API, REPO, 5, C.MARKER + "\nnew")
check("upsert: full page then empty page -> created", action == "created" and methods(f).count("GET") == 2)

f = Fake({1: [{"id": 5, "body": "quoting the marker\n" + C.MARKER}]})
action, cid = C.upsert(f, API, REPO, 5, C.MARKER + "\nnew")
check("upsert: marker quoted mid-body is not our comment", action == "created", str(action))

# ---- CLI against a local HTTP server (real transport, offline) ----
LOG = []


class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        LOG.append(("GET", self.path, self.headers.get("Authorization")))
        page = int(parse_qs(urlparse(self.path).query).get("page", ["1"])[0])
        self._send(200, [{"id": 77, "body": C.MARKER + "\nold"}] if page == 1 else [])

    def do_PATCH(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        LOG.append(("PATCH", self.path, body))
        self._send(200, {"id": 77, "body": body["body"]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        LOG.append(("POST", self.path, body))
        self._send(201, {"id": 78, "body": body["body"]})

    def log_message(self, *a):
        pass


srv = HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
local_api = f"http://127.0.0.1:{srv.server_port}"
tmp = tempfile.mkdtemp()


def run_cli(args, extra_env=None, api=local_api):
    env_vars = {"PATH": os.environ["PATH"], "GITHUB_TOKEN": "t0k", "GITHUB_API_URL": api,
                "GITHUB_REPOSITORY": REPO}
    for k, v in (extra_env or {}).items():
        if v is None:
            env_vars.pop(k, None)
        else:
            env_vars[k] = v
    return subprocess.run([sys.executable, "-I", POSTER] + args, env=env_vars, capture_output=True, text=True)


envp = os.path.join(tmp, "mech-review.json")
with open(envp, "w") as fh:
    json.dump(env([entry()]), fh)
summ = os.path.join(tmp, "summary.md")

LOG.clear()
p = run_cli(["--pr", "5", "--envelope", envp], {"GITHUB_STEP_SUMMARY": summ})
check("cli: fail entry exits 1", p.returncode == 1, p.stderr)
check("cli: PATCHes the existing marker comment", any(m == "PATCH" and u == "/repos/o/r/issues/comments/77" for m, u, _ in LOG), str(LOG))
check("cli: no POST when marker comment exists", LOG and not any(m == "POST" for m, _, _ in LOG), str(LOG))
check("cli: sends the bearer token", LOG and all(a == "Bearer t0k" for m, _, a in LOG if m == "GET"), str(LOG))
check("cli: edited body is the rendered comment",
      any(m == "PATCH" and b.get("body", "").startswith(C.MARKER) for m, _, b in LOG))
check("cli: step summary written", os.path.exists(summ) and C.MARKER in open(summ).read())

clean = os.path.join(tmp, "clean.json")
with open(clean, "w") as fh:
    json.dump(env([entry(sev="confirm")]), fh)
LOG.clear()
p = run_cli(["--pr", "5", "--envelope", clean])
check("cli: confirm-only exits 0", p.returncode == 0, p.stderr)

LOG.clear()
p = run_cli(["--pr", "5", "--envelope", os.path.join(tmp, "missing.json"), "--head", SHA,
             "--reason", "guard exited 2"])
check("cli: no usable result exits 4", p.returncode == 4, f"rc={p.returncode} {p.stderr}")
check("cli: crash edits the sticky comment, no duplicate", any(m == "PATCH" for m, _, _ in LOG) and not any(m == "POST" for m, _, _ in LOG), str(LOG))

p = run_cli(["--pr", "5", "--envelope", envp], {"GITHUB_TOKEN": None})
check("cli: missing GITHUB_TOKEN is a usage error (exit 2)", p.returncode == 2 and "GITHUB_TOKEN" in p.stderr, p.stderr)

p = run_cli(["--envelope", envp], {"GITHUB_STEP_SUMMARY": None})
check("cli: missing --pr is a usage error (exit 2)", p.returncode == 2 and "--pr" in p.stderr, p.stderr)

p = run_cli(["--pr", "5", "--envelope", envp], api="http://127.0.0.1:1")
check("cli: API unreachable exits 3", p.returncode == 3, f"rc={p.returncode} {p.stderr}")

srv.shutdown()
print("")
sys.exit(1 if FAILS else 0)
PY
