"""Comment poster: render the mech-review contract JSON into one sticky PR comment, find or edit it.

Pure render + exit code here; find-or-edit transport is injected (call(method, url, payload) -> JSON).
Stdlib only.
"""
import json
import re

MARKER = "<!-- mech-review -->"
COMMENT_LIMIT = 60000  # GitHub caps a comment at 65536 chars; keep headroom
OVERSIZE_ROWS = 50
CELL_MAX = 200


def _cell(text):
    s = str(text).replace("\r", " ").replace("\n", " ")
    if len(s) > CELL_MAX:
        s = s[:CELL_MAX - 1] + "…"
    return s.replace("|", "\\|")


def _fence(text):
    longest = max((len(m) for m in re.findall(r"`+", text)), default=0)
    return "`" * max(3, longest + 1)


def _label(e):
    """Human severity: a fail entry of class needs-human reads needs-human. The JSON keeps severity fail."""
    if e["severity"] == "fail" and e.get("class") == "needs-human":
        return "needs-human"
    return e["severity"]


def headline(env):
    """Summary line, `fail` read as `needs-human` when every fail entry is needs-human. Otherwise unchanged."""
    fails = [e for e in env["entries"] if e["severity"] == "fail"]
    if fails and all(e.get("class") == "needs-human" for e in fails) and env["summary"].startswith("fail "):
        return "needs-human " + env["summary"][len("fail "):]
    return env["summary"]


def _num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def _timing_lines(env):
    """One human line under the headline when R3 ran (its count and timing), and the slowest mutants when it is partial.
    The JSON block carries every field; a field that is not there is left out here too."""
    c = (env.get("checks") or {}).get("R3") or {}
    if c.get("status") not in ("pass", "fail", "partial"):
        return []
    t = c.get("timing") or {}
    tested, total = c.get("tested"), c.get("total")
    if tested is None and not t:
        return []
    parts = []
    if _num(tested):
        parts.append(f"{tested}/{total if _num(total) else '?'} mutants")
    if _num(t.get("wall_s")):
        parts.append(f"{round(t['wall_s'])}s wall")
    detail = []
    if _num(t.get("mutant_build_s")):
        detail.append(f"build {round(t['mutant_build_s'])}s")
    if _num(t.get("mutant_test_s")):
        detail.append(f"test {round(t['mutant_test_s'])}s")
    if _num(t.get("avg_s_per_mutant")):
        seg = f"avg {t['avg_s_per_mutant']:.1f}s per mutant"
        if detail:
            seg += f" ({', '.join(detail)})"
        parts.append(seg)
    elif detail:
        parts.append(f"({', '.join(detail)})")
    lines = ["R3 timing: " + ", ".join(parts)] if parts else []
    slow = [x for x in (t.get("slowest") or []) if isinstance(x, dict) and _num(x.get("s"))]
    if c.get("status") == "partial" and slow:
        names = [f"{_cell(x.get('name', '')).replace('`', chr(39))} {x['s']:.1f}s" for x in slow[:5]]
        lines.append("R3 slowest: " + ", ".join(names))
    return lines


def _table(entries):
    rows = [
        "| id | severity | file:line | problem | forbidden |",
        "|---|---|---|---|---|",
    ]
    for e in entries:
        rows.append(f"| {_cell(e['id'])} | {_cell(_label(e))} | {_cell(e['file'])}:{e['line']} | "
                    f"{_cell(e['problem'])} | {_cell(e['forbidden'])} |")
    return "\n".join(rows)


def _body(env, shown, json_text):
    entries = env["entries"]
    lines = [MARKER, "## mech-review", "", f"**{headline(env)}**", ""]
    timing = _timing_lines(env)
    if timing:
        lines += timing + [""]
    lines += [f"head `{env['head']}`", ""]
    if not entries:
        lines.append("No entries.")
    else:
        lines.append(_table(shown))
        if len(shown) < len(entries):
            lines += ["", f"_showing first {len(shown)} of {len(entries)} entries_"]
    lines.append("")
    if json_text is None:
        lines.append("JSON omitted (comment size limit). Full result: `mech-review-json` artifact of this run.")
    else:
        fence = _fence(json_text)
        lines += ["### JSON", "", f"{fence}json", json_text, fence]
    return "\n".join(lines) + "\n"


def render(env):
    json_text = json.dumps(env, indent=2)
    full = _body(env, env["entries"], json_text)
    if len(full) <= COMMENT_LIMIT:
        return full
    return _body(env, env["entries"][:OVERSIZE_ROWS], None)


def render_crash(head, reason):
    return "\n".join([
        MARKER,
        "## mech-review",
        "",
        f"**no result** for head `{head}`",
        "",
        f"reason: {reason}",
        "",
        "The check fails. See the job log.",
        "",
    ])


def exit_code(env):
    return 1 if any(e["severity"] == "fail" for e in env["entries"]) else 0


class ApiError(Exception):
    def __init__(self, status, body):
        super().__init__(f"GitHub API {status}: {body}")
        self.status = status
        self.body = body


PER_PAGE = 100
DEFAULT_AUTHOR = "github-actions[bot]"  # login of the GITHUB_TOKEN actor; override with MECH_COMMENT_AUTHOR


def find_marker(call, api, repo, pr, author=DEFAULT_AUTHOR):
    """Id of the first issue comment by `author` whose body starts with MARKER, paging until a short page. None if absent."""
    page = 1
    while True:
        items = call("GET", f"{api}/repos/{repo}/issues/{pr}/comments?per_page={PER_PAGE}&page={page}", None)
        for c in items:
            if c.get("body", "").startswith(MARKER) and (c.get("user") or {}).get("login") == author:
                return c["id"]
        if len(items) < PER_PAGE:
            return None
        page += 1


def upsert(call, api, repo, pr, body, author=DEFAULT_AUTHOR):
    """Edit the author's marker comment in place, or create it. Returns (action, comment id)."""
    cid = find_marker(call, api, repo, pr, author)
    if cid is None:
        res = call("POST", f"{api}/repos/{repo}/issues/{pr}/comments", {"body": body})
        return "created", res["id"]
    call("PATCH", f"{api}/repos/{repo}/issues/comments/{cid}", {"body": body})
    return "updated", cid


def publish(call, api, repo, pr, head, body, author=DEFAULT_AUTHOR):
    """upsert, unless the PR head has moved past `head`: then leave the comment alone.
    Returns ("superseded", current head sha) or the upsert result. Check-then-write: a
    newer run landing between the GET and the write can still be overwritten."""
    current = call("GET", f"{api}/repos/{repo}/pulls/{pr}", None)["head"]["sha"]
    if current != head:
        return "superseded", current
    return upsert(call, api, repo, pr, body, author)


def http_call(token):
    """Real transport: urllib with the workflow token. Non-2xx and unreachable hosts raise ApiError."""
    import urllib.error
    import urllib.request

    def call(method, url, payload=None):
        data = None if payload is None else json.dumps(payload).encode()
        req = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "Content-Type": "application/json",
            "User-Agent": "ek-mech-review",
        })
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e:
            raise ApiError(e.code, e.read().decode(errors="replace")) from None
        except urllib.error.URLError as e:
            raise ApiError(0, f"unreachable: {e.reason}") from None
        return json.loads(raw) if raw else None

    return call
