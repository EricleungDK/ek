"""Git access for one review of base...head: refs, the merge base, changed files, added lines, blobs."""
import re
import subprocess
from collections import namedtuple

HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
Change = namedtuple("Change", "status old new")
# one review of mb..head: what every check needs. mb: merge base sha; project_dir: crate dir under the repo root
Review = namedtuple("Review", "repo mb head adapter test_globs project_dir", defaults=(".",))


class Die(Exception):
    """usage or git error: CLI exits 2."""


def git(repo, *args):
    r = subprocess.run(["git", "-c", "core.quotepath=off", "-C", repo, *args], capture_output=True)
    if r.returncode:
        raise Die(r.stderr.decode("utf-8", "replace").strip() or f"git {args[0]} failed")
    return r.stdout.decode("utf-8", "surrogateescape")  # non-utf8 names/content survive; re-encoded on the way back to git


def resolve(repo, ref):
    try:
        return git(repo, "rev-parse", "--verify", "-q", ref + "^{commit}").strip()
    except Die:
        raise Die(f"unknown ref: {ref}")


def merge_base(repo, base_ref, head_ref):
    """(base sha, head sha, merge base sha) of two refs."""
    base = resolve(repo, base_ref)
    head = resolve(repo, head_ref)
    try:
        return base, head, git(repo, "merge-base", base, head).strip()
    except Die:
        raise Die(f"no merge base for {base_ref} and {head_ref}")


def changes(repo, mb, head):
    toks = git(repo, "diff", "--no-ext-diff", "--no-textconv", "-z", "--name-status", "-M", mb, head).split("\0")
    out, i = [], 0
    while i < len(toks) and toks[i]:
        st = toks[i][0]
        if st in "RC":
            old, new, i = toks[i + 1], toks[i + 2], i + 3
        else:
            old = new = toks[i + 1]
            i += 2
        out.append(Change(st, None if st == "A" else old, None if st == "D" else new))
    return out


ESC = {"a": 7, "b": 8, "t": 9, "n": 10, "v": 11, "f": 12, "r": 13, '"': 34, "\\": 92}


def unquote(s):
    """git C-style quoted path body -> str (octal escapes are utf-8 bytes)."""
    b, i = bytearray(), 0
    while i < len(s):
        if s[i] == "\\" and re.match(r"[0-7]{3}", s[i + 1:i + 4]):
            b.append(int(s[i + 1:i + 4], 8))
            i += 4
        elif s[i] == "\\":
            b.append(ESC.get(s[i + 1], ord(s[i + 1])))
            i += 2
        else:
            b.extend(s[i].encode("utf-8", "surrogateescape"))
            i += 1
    return b.decode("utf-8", "surrogateescape")


def added_lines(repo, mb, head):
    """{new path: [(head line no, text)]} for lines added in mb..head (hunk counts, so '---'/'+++' content is safe)."""
    out, cur, ln, rem_old, rem_new = {}, None, 0, 0, 0
    text = git(repo, "diff", "--no-ext-diff", "--no-textconv", "--text", "-U0", "-M", "--src-prefix=a/", "--dst-prefix=b/", mb, head)
    for line in text.split("\n"):
        if rem_old or rem_new:
            if line.startswith("+"):
                out[cur].append((ln, line[1:]))
                ln, rem_new = ln + 1, rem_new - 1
            elif line.startswith("-"):
                rem_old -= 1
            elif line.startswith(" "):
                ln, rem_old, rem_new = ln + 1, rem_old - 1, rem_new - 1
            continue
        if line.startswith("+++ "):
            p = line[4:]
            if p.endswith("\t"):  # git ends names containing spaces with a tab
                p = p[:-1]
            if p.startswith('"') and p.endswith('"'):
                p = unquote(p[1:-1])
            cur = p[2:] if p.startswith("b/") else None
            if cur:
                out.setdefault(cur, [])
        elif line.startswith("@@"):
            m = HUNK.match(line)
            rem_old = int(m.group(2)) if m.group(2) is not None else 1
            rem_new = int(m.group(4)) if m.group(4) is not None else 1
            ln = int(m.group(3))
    return out


def blob(repo, rev, path):
    return git(repo, "cat-file", "blob", f"{rev}:{path}")
