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


def _table(entries):
    rows = [
        "| id | severity | file:line | problem | forbidden |",
        "|---|---|---|---|---|",
    ]
    for e in entries:
        rows.append(f"| {_cell(e['id'])} | {_cell(e['severity'])} | {_cell(e['file'])}:{e['line']} | "
                    f"{_cell(e['problem'])} | {_cell(e['forbidden'])} |")
    return "\n".join(rows)


def _body(env, shown, json_text):
    entries = env["entries"]
    lines = [MARKER, "## mech-review", "", f"**{env['summary']}**", "", f"head `{env['head']}`", ""]
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
