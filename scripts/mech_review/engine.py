"""Mechanical review engine: git access, checks, contract envelope."""
import hashlib
import json
import os
import re
import subprocess
from collections import Counter, namedtuple

from .globs import any_glob
from .stack import ADAPTERS

PLUGIN = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".claude-plugin", "plugin.json"))
CHECKS = ("R1", "R2", "R3", "R4")
HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
ID = re.compile(r"\b(?:R[1-4]|CI)-[0-9a-f]{8}\b")
LIST = re.compile(r"^\s*[-*]\s+")
BOLD_HEAD = re.compile(r"^\*\*.*\*\*:?$")
GUARD_HEAD = re.compile(r"^(?:#+\s*)?\**\s*guard exceptions\s*\**\s*:?\s*$", re.I)
SUPPRESS = re.compile(r"#!?\[\s*(allow|expect)\s*\((.*?)\)\s*\]")
Change = namedtuple("Change", "status old new")


class Die(Exception):
    """usage or git error: CLI exits 2."""


def ek_version():
    with open(PLUGIN) as f:
        return json.load(f)["version"]


def git(repo, *args):
    r = subprocess.run(["git", "-c", "core.quotepath=off", "-C", repo, *args], capture_output=True)
    if r.returncode:
        raise Die(r.stderr.decode("utf-8", "replace").strip() or f"git {args[0]} failed")
    return r.stdout.decode("utf-8", "replace")


def resolve(repo, ref):
    try:
        return git(repo, "rev-parse", "--verify", "-q", ref + "^{commit}").strip()
    except Die:
        raise Die(f"unknown ref: {ref}")


def entry(check, file, line, key, cls, severity, problem, hint, forbidden):
    """id = <check>-<sha1(check+file+key)[:8]>; key is the test fn or rule name, never a line number."""
    eid = f"{check}-" + hashlib.sha1((check + file + key).encode()).hexdigest()[:8]
    return {"id": eid, "check": check, "class": cls, "severity": severity, "file": file, "line": line,
            "problem": problem, "hint": hint, "forbidden": forbidden}


def finalize(entries):
    seen, out = set(), []
    for e in entries:
        if e["id"] not in seen:
            seen.add(e["id"])
            out.append(e)
    # file-level entries (line 0) sort after line-anchored ones within a file
    return sorted(out, key=lambda e: (e["file"], e["line"] == 0, e["line"], e["id"]))


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


ESC = {"n": 10, "t": 9, '"': 34, "\\": 92}


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
            b.extend(s[i].encode())
            i += 1
    return b.decode("utf-8", "replace")


def added_lines(repo, mb, head):
    """{new path: [(head line no, text)]} for lines added in mb..head (hunk counts, so '---'/'+++' content is safe)."""
    out, cur, ln, rem_old, rem_new = {}, None, 0, 0, 0
    text = git(repo, "diff", "--no-ext-diff", "--no-textconv", "-U0", "-M", "--src-prefix=a/", "--dst-prefix=b/", mb, head)
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


def unmatched(xs, ys):
    """xs minus exact (fn, kind, left, right) matches in ys, multiset-aware."""
    key = lambda a: (a.fn, a.kind, a.left, a.right)
    pool = Counter(key(y) for y in ys)
    out = []
    for x in xs:
        if pool[key(x)]:
            pool[key(x)] -= 1
        else:
            out.append(x)
    return out


def blob(repo, rev, path):
    return git(repo, "cat-file", "blob", f"{rev}:{path}")


def r2(repo, mb, head, adapter, test_globs, protected_globs):
    entries = []
    added = added_lines(repo, mb, head)
    for ch in changes(repo, mb, head):
        if any_glob(ch.old or "", protected_globs) or any_glob(ch.new or "", protected_globs):
            entries.append(entry("R2", ch.new or ch.old, 0, "protected-path", "needs-human", "fail",
                                 f"protected path changed: {ch.new or ch.old}",
                                 "move this change to its own human-reviewed PR, or list the id under Guard exceptions with a reason",
                                 "editing CI, gate scripts or agent docs to get the gate green"))
        # a source file renamed to a non-source path is a deletion; a non-source file renamed to source is an addition
        old = ch.old if ch.old and adapter.classify(ch.old, test_globs) is not None else None
        new = ch.new if ch.new and adapter.classify(ch.new, test_globs) is not None else None
        if old is None and new is None:
            continue
        path = new or old
        before = blob(repo, mb, old) if old else None
        after = blob(repo, head, new) if new else None
        bfns = adapter.test_fns(before) if before is not None else []
        afns = adapter.test_fns(after) if after is not None else []
        names = {f.name for f in afns}
        by_name = {f.name: f for f in bfns}
        for f in bfns:
            if f.name not in names:
                entries.append(entry("R2", path, f.line, f.name, "agent-fixable", "fail",
                                     f"test fn `{f.name}` removed",
                                     "restore the test and make the code satisfy it; a removed test is not a fix",
                                     "deleting or renaming a test to hide a failure"))
        for f in afns:
            old = by_name.get(f.name)
            if "ignore" in f.markers and not (old and "ignore" in old.markers):
                entries.append(entry("R2", path, f.line, f"ignore:{f.name}", "agent-fixable", "fail",
                                     f"test `{f.name}` marked #[ignore]",
                                     "make it pass or fix the code it covers; do not mark it ignored",
                                     "#[ignore] / skip / xfail / only on a test"))
        bas = [a for a in adapter.assertions(before) if a.scope] if before is not None else []
        aas = [a for a in adapter.assertions(after) if a.scope] if after is not None else []
        # assert count: asserts lost from surviving test fns (or module-level test code); removed fns are their own entry
        head_fns = {f.name for f in afns}
        nb = sum(1 for a in bas if a.fn is None or a.fn in head_fns)
        if before is not None and len(aas) < nb:
            entries.append(entry("R2", path, 0, "assert-count", "agent-fixable", "fail",
                                 f"assertions in `{path}` dropped from {nb} to {len(aas)}",
                                 "restore the dropped assertions; strengthen a test instead of removing one",
                                 f"fewer asserts in changed test file {path}"))
        # expected value: same fn, one operand unchanged (whitespace-normalized), the other changed
        removed = unmatched(bas, aas)
        added_a = unmatched(aas, bas)
        used = set()
        for r in removed:
            if r.kind not in ("eq", "ne"):
                continue
            for i, h in enumerate(added_a):
                if i in used or h.fn != r.fn or h.kind != r.kind:
                    continue
                l_same, r_same = h.left == r.left, h.right == r.right
                if l_same == r_same:
                    continue
                used.add(i)
                unchanged = r.left if l_same else r.right
                was, now = (r.right, h.right) if l_same else (r.left, h.left)
                where = r.fn or "<module>"
                entries.append(entry("R2", path, h.line, f"expected:{r.fn or ''}|{unchanged}", "agent-fixable", "confirm",
                                     f"expected value changed in `{where}`: was {was}, now {now}",
                                     "confirm the new value is the spec'd behaviour, not the buggy output",
                                     "editing an expected value to match the code's current output"))
                break
        if new is not None:
            added_nums = {ln for ln, _ in added.get(new, [])}
            for sup in adapter.suppressions(after):
                if sup.reason or not any(ln in added_nums for ln in range(sup.line, sup.end_line + 1)):
                    continue
                entries.append(entry("R2", new, sup.line, sup.lints, "agent-fixable", "fail",
                                     f"#[{sup.kind}({sup.lint_text})] added without a reason",
                                     'fix the lint, or give the suppression a reason: #[allow(lint, reason = "...")]',
                                     "silencing a lint without a reason"))
    return entries


PLACEHOLDER = {"tbd", "todo", "n a", "na", "none", "nothing", "fixme", "wip", "xxx"}


def guard_exceptions(pr_body):
    """ids on list items under a 'Guard exceptions' heading, with a real reason.
    The section ends at any heading or bold-only line. Reason needs >= 3 letters and not a placeholder."""
    ids, in_sec = set(), False
    for line in (pr_body or "").split("\n"):
        s = line.strip()
        if GUARD_HEAD.match(s):
            in_sec = True
            continue
        if s.startswith("#") or BOLD_HEAD.match(s):
            in_sec = False
            continue
        if not (in_sec and LIST.match(line)):
            continue
        for m in ID.finditer(line):
            words = re.sub(r"[^A-Za-z]+", " ", line[:m.start()] + " " + line[m.end():]).strip().lower()
            if len(words.replace(" ", "")) >= 3 and words not in PLACEHOLDER:
                ids.add(m.group(0))
    return ids


def apply_exceptions(entries, ids):
    """only agent-fixable fails downgrade; needs-human stays fail (reviewer cannot waive it from the PR body)."""
    for e in entries:
        if e["severity"] == "fail" and e["class"] == "agent-fixable" and e["id"] in ids:
            e["severity"] = "confirm"
    return entries


def envelope(base, head, entries):
    fails = [e for e in entries if e["severity"] == "fail"]
    confirms = [e for e in entries if e["severity"] == "confirm"]
    checks = {c: {"status": "skipped", "note": "not implemented"} for c in CHECKS}
    checks["R2"] = {"status": "fail" if fails else "pass", "note": f"{len(fails)} fail, {len(confirms)} confirm"}
    if not entries:
        summary = f"all pass {head}"
    elif fails:
        summary = f"fail {head} ({len(fails)} fail, {len(confirms)} confirm)"
    else:
        summary = f"pass {head}, {len(confirms)} confirm"
    return {"ek": ek_version(), "base": base, "head": head, "checks": checks, "entries": entries, "summary": summary}


def run(repo, base_ref, head_ref, stack, test_globs, protected_globs=(), pr_body=None):
    base = resolve(repo, base_ref)
    head = resolve(repo, head_ref)
    try:
        mb = git(repo, "merge-base", base, head).strip()
    except Die:
        raise Die(f"no merge base for {base_ref} and {head_ref}")
    adapter = ADAPTERS[stack]()
    entries = apply_exceptions(finalize(r2(repo, mb, head, adapter, test_globs, list(protected_globs))),
                               guard_exceptions(pr_body))
    return envelope(base, head, entries)
