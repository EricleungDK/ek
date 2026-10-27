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
