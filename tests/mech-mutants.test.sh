#!/bin/bash
# R3 mutation on the diff: outcome parsing against real cargo-mutants 27.1.0 output (tests/fixtures/mutants).
# Pure verdict tests first; the CLI runs cargo-mutants through a stub (MECH_TEST_STUB) added below.
source "$(dirname "$0")/lib.sh"
FX="$ROOT/tests/fixtures/mutants"

python3 -I - "$ROOT" <<'PY'
import json
import os
import shutil
import sys
import tempfile

ROOT = sys.argv[1]
sys.path.insert(0, os.path.join(ROOT, "scripts"))
FX = os.path.join(ROOT, "tests", "fixtures", "mutants")
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


from mech_review import mutants as M  # noqa: E402
from mech_review.stack import RustAdapter  # noqa: E402

A = RustAdapter()
TG = ["tests/**"]
TIMEOUT = "timeout"


def v(case, rc, text=""):
    return M.verdict(os.path.join(FX, case), rc, text, A, TG)


# ---- MISSED -> fail entry ----
chk, ents = v("missed", 2, "")
check("missed: status fail", chk["status"] == "fail", str(chk))
check("missed: one entry per MISSED mutant (11)", len(ents) == 11 and all(e["severity"] == "fail" for e in ents),
      str(len(ents)))
e0 = ents[0]
check("missed: entry check R3, class agent-fixable", e0["check"] == "R3" and e0["class"] == "agent-fixable", str(e0))
check("missed: file and line from the mutant span", e0["file"] == "src/lib.rs" and e0["line"] == 2, str(e0))
check("missed: problem carries the mutant", "MISSED mutant" in e0["problem"] and "replace + with - in add" in e0["problem"], e0["problem"])
check("missed: forbidden names the MISSED mutant", e0["forbidden"].startswith("MISSED mutant"), e0["forbidden"])
check("missed: id is R3-<8 hex>", len(e0["id"]) == 11 and e0["id"].startswith("R3-"), e0["id"])
check("missed: note counts tested of total", chk["note"].startswith("17/17 tested"), chk["note"])
check("missed: tested and total fields", chk.get("tested") == 17 and chk.get("total") == 17, str(chk))

# ---- TIMEOUT ignored, MISSED still counted ----
chk, ents = v("timeout-missed", 3, "")
check("timeout+missed: status fail (2 missed)", chk["status"] == "fail", str(chk))
check("timeout+missed: 2 entries, timeout not one of them", len(ents) == 2
      and not any("spin" in e["problem"] for e in ents), str([e["problem"] for e in ents]))

# ---- all caught -> pass, no entries ----
chk, ents = v("caught", 0, "")
check("caught: status pass", chk["status"] == "pass", str(chk))
check("caught: no entries", ents == [], str(ents))

# ---- shards: each shard's own total ----
chk0, ents0 = v("shard-0-of-2", 2, "")
chk1, ents1 = v("shard-1-of-2", 2, "")
check("shard 0: 3 missed, total 9", len(ents0) == 3 and chk0["total"] == 9, str((len(ents0), chk0)))
check("shard 1: 8 missed, total 8", len(ents1) == 8 and chk1["total"] == 8, str((len(ents1), chk1)))

# ---- budget hit (rc timeout): partial when no MISSED so far ----
chk, ents = v("partial", TIMEOUT, "")
check("partial: status partial", chk["status"] == "partial", str(chk))
check("partial: note tested/total", chk["note"].startswith("7/15 tested"), chk["note"])
check("partial: tested and total fields", chk.get("tested") == 7 and chk.get("total") == 15, str(chk))
check("partial: no entries (does not block)", ents == [], str(ents))

# ---- budget hit with a MISSED already found: fail ----
chk, ents = v("missed", TIMEOUT, "")
check("budget hit with MISSED: status fail", chk["status"] == "fail" and len(ents) == 11, str(chk))

# ---- budget hit before any output: partial, total unknown ----
chk, ents = M.verdict(os.path.join(FX, "no-such-dir"), TIMEOUT, "", A, TG)
check("budget hit, no output: partial", chk["status"] == "partial", str(chk))
check("budget hit, no output: tested 0, total unknown", chk.get("tested") == 0 and chk.get("total") is None, str(chk))

# ---- no mutants in the diff: no output dir, exit 0 -> pass with the reason ----
chk, ents = M.verdict(os.path.join(FX, "no-such-dir"), 0, "", A, TG)
check("zero mutants: status pass", chk["status"] == "pass" and ents == [], str(chk))
check("zero mutants: note says 0 mutants", "0 mutants" in chk["note"], chk["note"])

# ---- baseline fails at head (exit 4): fail, agent-fixable, names the baseline ----
chk, ents = M.verdict(os.path.join(FX, "no-such-dir"), 4, "", A, TG)
check("baseline failed: status fail", chk["status"] == "fail" and len(ents) == 1, str(chk))
check("baseline failed: entry agent-fixable, names baseline", ents and ents[0]["class"] == "agent-fixable"
      and "baseline" in ents[0]["problem"], str(ents))

# ---- tool not runnable: n/a (env), never pass ----
chk, ents = M.verdict(os.path.join(FX, "no-such-dir"), None, "cargo: not found", A, TG)
check("tool missing (rc None): n/a", chk["status"] == "n/a" and "(env)" in chk["note"], str(chk))
chk, ents = M.verdict(os.path.join(FX, "no-such-dir"), 1, "error: could not find `Cargo.toml` in /x", A, TG)
check("cargo error (rc 1): n/a (env), first line in note", chk["status"] == "n/a" and "Cargo.toml" in chk["note"]
      and "(env)" in chk["note"], str(chk))

# ---- ids survive line moves: same mutant, shifted lines, same id ----
tmp = tempfile.mkdtemp()
try:
    for name in ("outcomes.json", "mutants.json"):
        shutil.copy(os.path.join(FX, "missed", name), tmp)
    m = json.load(open(os.path.join(tmp, "mutants.json")))
    for x in m:
        x["span"]["start"]["line"] += 5
        x["span"]["end"]["line"] += 5
    json.dump(m, open(os.path.join(tmp, "mutants.json"), "w"))
    o = json.load(open(os.path.join(tmp, "outcomes.json")))
    for oc in o["outcomes"]:
        if isinstance(oc["scenario"], dict):
            oc["scenario"]["Mutant"]["span"]["start"]["line"] += 5
    json.dump(o, open(os.path.join(tmp, "outcomes.json"), "w"))
    _, moved = M.verdict(tmp, 2, "", A, TG)
    _, base = v("missed", 2, "")
    check("ids: stable when line numbers move", sorted(e["id"] for e in moved) == sorted(e["id"] for e in base),
          str((sorted(e["id"] for e in moved), sorted(e["id"] for e in base))))
    check("ids: line moved in the entry", sorted(e["line"] for e in moved) != sorted(e["line"] for e in base))
finally:
    shutil.rmtree(tmp, ignore_errors=True)

sys.exit(1 if FAILS else 0)
PY
eq "$?" 0 "R3 verdict: MISSED, TIMEOUT, partial, n/a, skipped-by-zero, baseline fail, stable ids"

# ---- CLI: `mutants` runs cargo-mutants through the stub (MECH_TEST_STUB replaces argv[0]) ----
MR="$ROOT/scripts/mech-review.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export MECH_STUB_LOG="$T/calls.log" MECH_FX="$FX"; : > "$MECH_STUB_LOG"
# fake cargo-mutants: `mutants --version`, or a run with -o DIR and --shard k/n.
# MUT_FIXTURE names a fixture dir ({k} = shard index), MUT_RC the exit code, MUT_HANG=1 sleeps (budget kill).
MUT="$T/mutstub.sh"
cat > "$MUT" <<'SH'
#!/bin/bash
if [[ "$1" == mutants && "$2" == --version ]]; then echo "cargo-mutants 27.1.0"; exit 0; fi
out=""; shard=""; prev=""
for a in "$@"; do
  case "$prev" in -o|--output) out="$a" ;; --shard) shard="$a" ;; --in-diff) cp "$a" "$MECH_STUB_LOG.diff" ;; esac
  prev="$a"
done
k=${shard%%/*}
echo "$(pwd -P) | $*" >> "$MECH_STUB_LOG"
if [[ -n "${MUT_FIXTURE-}" && -n "$out" ]]; then
  fx="${MUT_FIXTURE//\{k\}/$k}"
  mkdir -p "$out/mutants.out"; cp -r "$MECH_FX/$fx/." "$out/mutants.out/"
fi
if [[ -n "${MUT_HANG-}" ]]; then sleep 30; fi
if [[ -n "${MUT_OUT-}" ]]; then printf '%s\n' "$MUT_OUT"; fi
exit "${MUT_RC:-0}"
SH
chmod +x "$MUT"

# mrepo <name> [tests-only]: base with src/lib.rs and tests/a.rs; head changes src (or only tests). sets R B H
mrepo() {
  R="$T/$1"; mkdir -p "$R/src" "$R/tests"; git -C "$R" init -q -b main
  printf 'pub fn add(a: i32, b: i32) -> i32 { a + b }\n' > "$R/src/lib.rs"
  printf '#[test]\nfn adds() {\n    assert_eq!(add(1, 2), 3);\n}\n' > "$R/tests/a.rs"
  [[ -n "${NO_MANIFEST-}" ]] || printf '[package]\nname = "x"\nversion = "0.1.0"\n' > "$R/Cargo.toml"
  git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@t commit -qm base; B=$(git -C "$R" rev-parse HEAD)
  if [[ "${2-}" == tests-only ]]; then
    printf '#[test]\nfn adds() {\n    assert_eq!(add(1, 2), 3);\n    assert_eq!(add(0, 0), 0);\n}\n' > "$R/tests/a.rs"
  else
    printf 'pub fn add(a: i32, b: i32) -> i32 { a + b } // fixed\n' > "$R/src/lib.rs"
  fi
  git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@t commit -qm head; H=$(git -C "$R" rev-parse HEAD)
}
# mut <args>: mutants subcommand on $R $B $H with the stub
mut() { MECH_TEST_STUB="$MUT" python3 -I "$MR" mutants --repo "$R" --base "$B" --head "$H" --stack rust --test-paths 'tests/**' "$@"; }

# MISSED -> fail: exit 1, one R3 entry per MISSED mutant, exact summary, skipped checks named
mrepo missed
out=$(MUT_FIXTURE=missed MUT_RC=2 mut); rc=$?
eq "$rc" 1 "missed: exit 1"
eq "$(jq -r .checks.R3.status <<<"$out")" fail "missed: R3 fail"
eq "$(jq -r '[.entries[] | select(.check=="R3")] | length' <<<"$out")" 11 "missed: 11 R3 entries"
eq "$(jq -r '.entries[0].class' <<<"$out")" agent-fixable "missed: entry agent-fixable"
eq "$(jq -r '.entries[0].file' <<<"$out")" src/lib.rs "missed: entry names the file"
has "$(jq -r '.entries[0].problem' <<<"$out")" "MISSED mutant src/lib.rs:2:11: replace + with - in add" "missed: problem is the mutant"
has "$(jq -r '.entries[0].id' <<<"$out")" "R3-" "missed: R3 id"
eq "$(jq -r .summary <<<"$out")" "fail $H (11 fail, 0 confirm; ran: R3; skipped: R1 R2 R4)" "missed: summary"
has "$(cat "$MECH_STUB_LOG")" "--in-diff" "missed: cargo-mutants gets --in-diff"
lacks "$(cat "$MECH_STUB_LOG")" " --timeout" "missed: per-mutant timeout auto, no --timeout sent (was 120 s)"
has "$(cat "$MECH_STUB_LOG")" "--colors never" "missed: no colour codes"
lacks "$(cat "$MECH_STUB_LOG")" "--shard" "missed: no shard flag without --shard"
lacks "$(cat "$MECH_STUB_LOG")" "$R |" "missed: runs in a worktree, not the caller checkout"
eq "$(git -C "$R" worktree list | wc -l)" 1 "missed: no worktree left behind"

# all caught -> pass, exit 0, nothing missed
mrepo caught
out=$(MUT_FIXTURE=caught MUT_RC=0 mut); rc=$?
eq "$rc" 0 "caught: exit 0"
eq "$(jq -r .checks.R3.status <<<"$out")" pass "caught: R3 pass"
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 0 confirm; ran: R3; skipped: R1 R2 R4)" "caught: summary names ran and skipped"

# budget hit with no MISSED: partial (7/15), exit 0, does not block, the run is killed promptly
mrepo partial
SECONDS=0
out=$(MUT_FIXTURE=partial MUT_RC=0 MUT_HANG=1 mut --mutation-budget 0.02); rc=$?
eq "$rc" 0 "partial: exit 0 (does not block)"
eq "$(jq -r .checks.R3.status <<<"$out")" partial "partial: R3 partial"
has "$(jq -r .checks.R3.note <<<"$out")" "7/15 tested" "partial: note tested/total"
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 1 confirm; ran: R3; partial: R3 (7/15); skipped: R1 R2 R4)" "partial: summary names partial"
eq "$(jq -r '[.checks[] | select(.status=="pass")] | length' <<<"$out")" 0 "partial: never all pass"
[[ $SECONDS -lt 10 ]] && ok "partial: budget kill is prompt" || fail "partial: budget kill took ${SECONDS}s"

# tool not installed: n/a (env), named in the summary, never pass for R3
mrepo nocmd
out=$(env -u MECH_TEST_STUB python3 -I "$MR" mutants --repo "$R" --base "$B" --head "$H" --stack rust --test-paths 'tests/**' --mutants-cmd "ekit-no-such-cargo mutants"); rc=$?
eq "$rc" 0 "not installed: exit 0 (n/a is not a failure)"
eq "$(jq -r .checks.R3.status <<<"$out")" n/a "not installed: R3 n/a"
has "$(jq -r .checks.R3.note <<<"$out")" "(env)" "not installed: note says env"
has "$(jq -r .checks.R3.note <<<"$out")" "\`ekit-no-such-cargo mutants\` not runnable" "not installed: note names the tool"
has "$(jq -r .checks.R3.note <<<"$out")" "install step" "not installed: note says check the install step"
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 0 confirm; ran: none; skipped: R1 R2 R4; n/a: R3)" "not installed: summary names n/a"

# unexpected exit (cargo cannot find a manifest): n/a (env), not fail, not pass
# unexpected exit: n/a (env), keeps the first output line, names the job log
mrepo unexit
out=$(MUT_RC=1 MUT_OUT=$'error: boom\nsecond line' mut); rc=$?
eq "$(jq -r .checks.R3.status <<<"$out")" n/a "unexpected exit 1: R3 n/a"
has "$(jq -r .checks.R3.note <<<"$out")" "cargo-mutants exit 1 (env): error: boom" "unexpected exit: note keeps the first output line"
has "$(jq -r .checks.R3.note <<<"$out")" "see the job log" "unexpected exit: note names the job log"
lacks "$(jq -r .checks.R3.note <<<"$out")" "second line" "unexpected exit: only the first line in the note"

# no Cargo.toml in the project dir: n/a, detected before cargo-mutants runs, the note names project-dir
NO_MANIFEST=1 mrepo nomanifest
: > "$MECH_STUB_LOG"
out=$(MUT_RC=0 mut); rc=$?
eq "$(jq -r .checks.R3.status <<<"$out")" n/a "no manifest: R3 n/a"
eq "$(jq -r .checks.R3.note <<<"$out")" "no Cargo.toml in .: set project-dir" "no manifest: note names the input to set"
eq "$(wc -l < "$MECH_STUB_LOG" | tr -d ' ')" 0 "no manifest: cargo-mutants not invoked"
eq "$rc" 0 "no manifest: n/a is not a failure, exit 0"

# baseline fails at head (exit 4): R3 fail, agent-fixable
mrepo base4
out=$(MUT_RC=4 mut); rc=$?
eq "$rc" 1 "baseline fails: exit 1"
eq "$(jq -r .checks.R3.status <<<"$out")" fail "baseline fails: R3 fail"
has "$(jq -r '.entries[0].id' <<<"$out")" "R3-" "baseline fails: entry has an R3 id"
eq "$(jq -r '.entries[0] | has("_key")' <<<"$out")" false "baseline fails: no internal _key in the entry"

# no production file changed: skipped with the reason, cargo-mutants never runs
mrepo docs tests-only
: > "$MECH_STUB_LOG"
out=$(MUT_FIXTURE=missed MUT_RC=2 mut); rc=$?
eq "$rc" 0 "no prod change: exit 0"
eq "$(jq -r .checks.R3.status <<<"$out")" skipped "no prod change: R3 skipped"
has "$(jq -r .checks.R3.note <<<"$out")" "no production file changed" "no prod change: note"
eq "$(wc -l < "$MECH_STUB_LOG" | tr -d ' ')" 0 "no prod change: cargo-mutants not invoked"

# shards: --shard k/n is passed through (0-based, as cargo-mutants numbers them); a bad shard is a usage error
mrepo shards
out=$(MUT_FIXTURE='shard-{k}-of-2' MUT_RC=2 mut --shard 1/2); rc=$?
has "$(cat "$MECH_STUB_LOG")" "--shard 1/2" "shard: --shard 1/2 passed to cargo-mutants"
eq "$(jq -r '[.entries[] | select(.check=="R3")] | length' <<<"$out")" 8 "shard 1/2: its 8 MISSED only"
out=$(MECH_TEST_STUB="$MUT" python3 -I "$MR" mutants --repo "$R" --base "$B" --head "$H" --stack rust --shard 2/2 2>&1); rc=$?
eq "$rc" 2 "shard 2/2: usage error exit 2"
out=$(MECH_TEST_STUB="$MUT" python3 -I "$MR" mutants --repo "$R" --base "$B" --head "$H" --stack rust --mutation-budget abc 2>&1); rc=$?
eq "$rc" 2 "mutation-budget not a number: usage error exit 2"

# ---- project dir: crate in sub/: cargo-mutants runs there on a crate-relative diff; entry paths map back to repo root ----
# msub <name>: base and head change sub/src/lib.rs; README.md (outside the crate) changes too. sets R B H
msub() {
  R="$T/$1"; mkdir -p "$R/sub/src" "$R/sub/tests"; git -C "$R" init -q -b main
  printf 'pub fn add(a: i32, b: i32) -> i32 { a + b }\n' > "$R/sub/src/lib.rs"
  printf '#[test]\nfn adds() {\n    assert_eq!(add(1, 2), 3);\n}\n' > "$R/sub/tests/a.rs"
  printf 'notes\n' > "$R/README.md"
  printf '[package]\nname = "x"\nversion = "0.1.0"\n' > "$R/sub/Cargo.toml"
  git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@t commit -qm base; B=$(git -C "$R" rev-parse HEAD)
  printf 'pub fn add(a: i32, b: i32) -> i32 { a + b } // fixed\n' > "$R/sub/src/lib.rs"
  printf 'notes 2\n' > "$R/README.md"
  git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t@t commit -qm head; H=$(git -C "$R" rev-parse HEAD)
}
# msub_mut <args>: mutants subcommand on the msub repo, crate in sub/
msub_mut() { MECH_TEST_STUB="$MUT" python3 -I "$MR" mutants --repo "$R" --base "$B" --head "$H" --stack rust --test-paths 'sub/tests/**' "$@"; }

msub subm
: > "$MECH_STUB_LOG"; rm -f "$MECH_STUB_LOG.diff"
out=$(MUT_FIXTURE=missed MUT_RC=2 msub_mut --project-dir sub); rc=$?
eq "$rc" 1 "project dir: MISSED in the crate: exit 1"
eq "$(jq -r '[.entries[] | select(.check=="R3")] | length' <<<"$out")" 11 "project dir: 11 R3 entries"
eq "$(jq -r '.entries[0].file' <<<"$out")" sub/src/lib.rs "project dir: entry file is the repo-root path"
has "$(jq -r '.entries[0].problem' <<<"$out")" "MISSED mutant sub/src/lib.rs:2:11" "project dir: problem names the repo-root path"
has "$(cat "$MECH_STUB_LOG")" "/sub | " "project dir: cargo-mutants runs in the crate dir"
has "$(cat "$MECH_STUB_LOG.diff")" "+++ b/src/lib.rs" "project dir: --in-diff paths are crate-relative"
lacks "$(cat "$MECH_STUB_LOG.diff")" "sub/src" "project dir: no repo-root path in --in-diff"
lacks "$(cat "$MECH_STUB_LOG.diff")" "README.md" "project dir: changes outside the crate are not in --in-diff"

msub subnone
out=$(MUT_FIXTURE=missed MUT_RC=2 msub_mut --project-dir nosuch 2>"$T/err"); rc=$?
eq "$rc" 1 "project dir missing at head: exit 1, a result"
lacks "$(cat "$T/err")" Traceback "project dir missing at head: no traceback"
eq "$(jq -r .checks.R3.status <<<"$out")" fail "project dir missing at head: R3 fail"
has "$(jq -r '.entries[0].problem' <<<"$out")" "project dir nosuch" "project dir missing at head: problem names the dir"

for bad in ../x /abs; do
  err=$(msub_mut --project-dir "$bad" 2>&1 >/dev/null); rc=$?
  eq "$rc" 2 "mutants project dir '$bad': usage error exit 2"
  has "$err" "under the repo root" "mutants project dir '$bad': usage error names the rule"
done

# ---- merge: shard envelopes -> one R3 envelope; a missing or stale shard is a CI fail that keeps the other shards ----
MG="$T/merge"; mkdir -p "$MG"
mrepo mshards
MUT_FIXTURE='shard-{k}-of-2' MUT_RC=2 mut --shard 0/2 > "$MG/s0.json"
MUT_FIXTURE='shard-{k}-of-2' MUT_RC=2 mut --shard 1/2 > "$MG/s1.json"
mg() { python3 -I "$MR" merge --repo "$R" --base "$B" --head "$H" --stack rust --shards "$@"; }

out=$(mg 2 --envelope 0="$MG/s0.json" --envelope 1="$MG/s1.json"); rc=$?
eq "$rc" 1 "merge: both shards with MISSED: exit 1"
eq "$(jq -r .checks.R3.status <<<"$out")" fail "merge: R3 fail"
eq "$(jq -r '[.entries[] | select(.check=="R3")] | length' <<<"$out")" 11 "merge: 3 + 8 entries kept"
eq "$(jq -r .summary <<<"$out")" "fail $H (11 fail, 0 confirm; ran: R3; skipped: R1 R2 R4)" "merge: summary"

out=$(mg 2 --envelope 0="$MG/s0.json"); rc=$?
eq "$rc" 1 "merge: missing shard 1 is a failure, exit 1"
eq "$(jq -r '[.entries[] | select(.check=="CI")] | length' <<<"$out")" 1 "merge: one CI entry for the missing shard"
eq "$(jq -r '[.entries[] | select(.check=="CI")][0].class' <<<"$out")" env "merge: CI entry class env"
has "$(jq -r '[.entries[] | select(.check=="CI")][0].problem' <<<"$out")" "shard 1/2" "merge: CI entry names shard 1/2"
eq "$(jq -r '[.entries[] | select(.check=="R3")] | length' <<<"$out")" 3 "merge: the other shard's entries still there"
eq "$(jq -r .checks.R3.status <<<"$out")" fail "merge: missing shard fails R3"

python3 -c "import json,sys; d=json.load(open(sys.argv[1])); d['head']='0'*40; json.dump(d, open(sys.argv[2],'w'))" "$MG/s1.json" "$MG/stale.json"
out=$(mg 2 --envelope 0="$MG/s0.json" --envelope 1="$MG/stale.json"); rc=$?
has "$(jq -r '[.entries[] | select(.check=="CI")][0].problem' <<<"$out")" "older head" "merge: a stale shard is no result (older head)"

# partial shard + passing shard: partial (12/20), exit 0, never all pass
mrepo mpartial
MUT_FIXTURE=partial MUT_RC=0 MUT_HANG=1 mut --shard 0/2 --mutation-budget 0.02 > "$MG/p0.json"
MUT_FIXTURE=caught MUT_RC=0 mut --shard 1/2 > "$MG/p1.json"
out=$(mg 2 --envelope 0="$MG/p0.json" --envelope 1="$MG/p1.json"); rc=$?
eq "$rc" 0 "merge partial: exit 0 (does not block)"
eq "$(jq -r .checks.R3.status <<<"$out")" partial "merge partial: R3 partial"
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 1 confirm; ran: R3; partial: R3 (12/20); skipped: R1 R2 R4)" "merge partial: summary sums tested/total"

out=$(mg 2 --envelope 5="$MG/s0.json"); rc=$?
eq "$rc" 2 "merge: shard index out of range is a usage error"

# ---- job merge: the mutants job owns R3; its absence is a skip, a crash is a fail ----
python3 -I - "$ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
from mech_review import merge as M

H = "a" * 40
BASE = "b" * 40
FAILS = 0


def check(name, cond, detail=""):
    global FAILS
    if cond:
        print(f"  ok   {name}")
    else:
        FAILS += 1
        print(f"  FAIL {name}\n       {detail}")


def env(checks, entries):
    fails = sum(1 for e in entries if e["severity"] == "fail")
    return {"ekit": "0.1.1", "base": BASE, "head": H, "checks": checks, "entries": entries,
            "summary": f"{'fail' if fails else 'pass'} {H}"}


def ent(check_name, eid, file="src/lib.rs", line=2):
    return {"id": eid, "check": check_name, "class": "agent-fixable", "severity": "fail", "file": file, "line": line,
            "problem": "p", "hint": "h", "forbidden": "f"}


r2 = env({"R1": {"status": "skipped", "note": "not run by r2"}, "R2": {"status": "pass", "note": "0 fail"},
          "R3": {"status": "skipped", "note": "not run by r2"}, "R4": {"status": "skipped", "note": "not run by r2"}}, [])
mut = env({"R1": {"status": "skipped", "note": "not run by mutants"}, "R2": {"status": "skipped", "note": "not run by mutants"},
           "R3": {"status": "fail", "note": "1/2 tested"}, "R4": {"status": "skipped", "note": "not run by mutants"}},
          [ent("R3", "R3-33333333")])

m = M.merge({"r2": r2, "mutants": mut}, {})
check("mutants present: R3 from the mutants job", m["checks"]["R3"]["status"] == "fail", str(m["checks"]))
check("mutants present: its R3 entry kept", [e["id"] for e in m["entries"]] == ["R3-33333333"], str(m["entries"]))
check("mutants present: summary names R3 ran", m["summary"] == f"fail {H} (1 fail, 0 confirm; ran: R2 R3; skipped: R1 R4)", m["summary"])

m = M.merge({"r2": r2}, {})
check("mutants absent: R3 skipped, no production change named",
      m["checks"]["R3"]["status"] == "skipped" and "no production file changed" in m["checks"]["R3"]["note"], str(m["checks"]["R3"]))

m = M.merge({"r2": r2, "mutants": None}, {"mutants": "no JSON from the job (see its log)"})
check("mutants crashed: R3 fail with the reason", m["checks"]["R3"]["status"] == "fail" and "no JSON" in m["checks"]["R3"]["note"],
      str(m["checks"]["R3"]))
check("mutants crashed: CI entry names the job", any(e["check"] == "CI" and "mutants" in e["problem"] for e in m["entries"]),
      str(m["entries"]))
check("mutants crashed: r2 checks survive", m["checks"]["R2"]["status"] == "pass", str(m["checks"]))
check("mutants: OWNS R3", M.OWNS.get("mutants") == ("R3",), str(M.OWNS))
ma = M.merge({"r2": r2}, {})
check("absent jobs: R1 and R4 say no job ran them (not the R3 reason)",
      all(ma["checks"][c]["note"] == "not run by any job" for c in ("R1", "R4")), str(ma["checks"]))

sys.exit(1 if FAILS else 0)
PY
eq "$?" 0 "job merge: mutants owns R3; absent is skipped; crashed is fail"

# ---- plan: does the mutants job run, and over how many shards (matrix). Cheap: git only, no toolchain ----
mrepo planprod
out=$(python3 -I "$MR" plan --repo "$R" --base "$B" --head "$H" --stack rust --test-paths 'tests/**' --shards 4); rc=$?
eq "$rc" 0 "plan: prod change exit 0"
eq "$(jq -c '{run,count,shards}' <<<"$out")" '{"run":true,"count":4,"shards":[0,1,2,3]}' "plan: prod change: 4 shards 0..3"
mrepo plandocs tests-only
out=$(python3 -I "$MR" plan --repo "$R" --base "$B" --head "$H" --stack rust --test-paths 'tests/**' --shards 4)
eq "$(jq -c '{run,count,shards}' <<<"$out")" '{"run":false,"count":1,"shards":[0]}' "plan: no prod change: not run, one placeholder shard"
out=$(python3 -I "$MR" plan --repo "$R" --base "$B" --head "$H" --stack rust --test-paths 'tests/**')
eq "$(jq -c '{run,count}' <<<"$out")" '{"run":false,"count":1}' "plan: default one shard"
python3 -I "$MR" plan --repo "$R" --base "$B" --head "$H" --stack rust --shards 0 >/dev/null 2>&1; rc=$?
eq "$rc" 2 "plan: --shards 0 is a usage error"

# merge needs no git checkout when given full SHAs (the report job has none)
out=$(python3 -I "$MR" merge --repo /no/such/checkout --base "$B" --head "$H" --stack rust --shards 2 --envelope 0="$MG/s0.json" --envelope 1="$MG/s1.json"); rc=$?
eq "$rc" 1 "merge: full SHAs with no checkout: exit 1, not a git error"
eq "$(jq -r .checks.R3.status <<<"$out")" fail "merge: full SHAs with no checkout: R3 fail"

# ---- runner stop: over budget returns "timeout" in bounded time, also when the run ignores SIGTERM and a child escaped its group ----
RUNNER_T="$T/runner"; mkdir -p "$RUNNER_T"
cat > "$RUNNER_T/ignores-term.sh" <<'SH'
#!/bin/bash
trap '' TERM
setsid sh -c 'trap "" TERM; exec sleep 9770123' &
wait
SH
cat > "$RUNNER_T/dies-on-term.sh" <<'SH'
#!/bin/bash
sleep 9770124
SH
python3 -I - "$ROOT" "$RUNNER_T" <<'PY'
import subprocess
import sys
import threading
import time

ROOT, RT = sys.argv[1], sys.argv[2]
sys.path.insert(0, ROOT + "/scripts")
from mech_review import mutants as M  # noqa: E402

FAILS = 0


def check(name, cond, detail=""):
    global FAILS
    if cond:
        print(f"  ok   {name}")
    else:
        FAILS += 1
        print(f"  FAIL {name}\n       {detail}")


def bounded(argv, budget, limit=30):
    """Run the default runner in a thread: (result or None if still stuck after limit, seconds)."""
    box = {}
    th = threading.Thread(target=lambda: box.setdefault("r", M.default_runner()(argv, RT, budget)), daemon=True)
    t0 = time.time()
    th.start()
    th.join(limit)
    return box.get("r") if not th.is_alive() else None, time.time() - t0


M.KILL_GRACE = 1
r, dt = bounded(["bash", RT + "/ignores-term.sh"], 0.5)
check("ignores SIGTERM and leaves a child outside the group: returns timeout", r is not None and r[0] == "timeout",
      f"result={r!r} after {dt:.1f}s")
check("ignores SIGTERM: returns within the bound (grace + reap), not stuck", dt < 15, f"{dt:.1f}s")

M.KILL_GRACE = 5
r, dt = bounded(["bash", RT + "/dies-on-term.sh"], 0.5)
check("honours SIGTERM: returns timeout before the grace ends", r is not None and r[0] == "timeout" and dt < 4,
      f"result={r!r} after {dt:.1f}s")

r, dt = bounded(["bash", "-c", "echo hi; exit 3"], 5)
check("normal exit: rc and output kept", r == (3, "hi\n"), repr(r))

subprocess.run(["pkill", "-f", "sleep 9770123"], capture_output=True)
subprocess.run(["pkill", "-f", "sleep 9770124"], capture_output=True)
sys.exit(1 if FAILS else 0)
PY
eq "$?" 0 "runner stop: bounded over budget, SIGTERM honoured, normal exit kept"

# ---- all: R3 is not in all; its note says where it runs; --help says so ----
mrepo allnote
out=$(env -u MECH_TEST_STUB python3 -I "$MR" all --repo "$R" --base "$B" --head "$H" --stack rust --test-paths 'tests/**' --test-cmd "ekit-no-such-toolchain test")
has "$(jq -r .checks.R3.note <<<"$out")" "not run by all" "all: R3 note says not run by all"
has "$(jq -r .checks.R3.note <<<"$out")" "mutants" "all: R3 note names the mutants subcommand"
has "$(python3 -I "$MR" --help)" "all" "help: all named"
has "$(python3 -I "$MR" --help)" "\`all\` = R1, R2 and R4" "help: all is R1, R2 and R4"

# ---- timing (#36): per shard from outcomes.json phase durations; wall from the runner; partial confirm ----
python3 -I - "$ROOT" <<'PY'
import json
import os
import shutil
import sys
import tempfile

ROOT = sys.argv[1]
sys.path.insert(0, os.path.join(ROOT, "scripts"))
FX = os.path.join(ROOT, "tests", "fixtures", "mutants")
FAILS = 0


def check(name, cond, detail=""):
    global FAILS
    if cond:
        print(f"  ok   {name}")
    else:
        FAILS += 1
        print(f"  FAIL {name}\n       {detail}")


from mech_review import mutants as M  # noqa: E402
from mech_review import merge  # noqa: E402
from mech_review.stack import RustAdapter  # noqa: E402

A = RustAdapter()
TG = ["tests/**"]


def load(case):
    return json.load(open(os.path.join(FX, case, "outcomes.json")))


def dur(phases, name):
    return sum(p["duration"] for p in phases if p["phase"] == name)


def mutant_rows(doc):
    return [oc for oc in doc["outcomes"] if isinstance(oc["scenario"], dict)]


def baseline(doc):
    return next(oc for oc in doc["outcomes"] if oc["scenario"] == "Baseline")


def near(a, b, tol=0.01):
    return a is not None and b is not None and abs(a - b) <= tol


doc = load("missed")
rows = mutant_rows(doc)
exp_mb = sum(dur(oc["phase_results"], "Build") for oc in rows)
exp_mt = sum(dur(oc["phase_results"], "Test") for oc in rows)
exp_top = sorted(((oc["scenario"]["Mutant"]["name"], dur(oc["phase_results"], "Build") + dur(oc["phase_results"], "Test"))
                  for oc in rows), key=lambda x: -x[1])[:5]

# ---- fixture timing: baseline, mutant sums, average, five slowest ----
chk, ents = M.verdict(os.path.join(FX, "missed"), 2, "", A, TG, wall_s=12.345)
t = chk.get("timing", {})
check("timing: present on the check", bool(t), str(chk))
check("timing: wall from the runner, 2 dp", t.get("wall_s") == 12.35 or t.get("wall_s") == 12.34, str(t))
check("timing: baseline build from the Baseline scenario",
      near(t.get("baseline_build_s"), dur(baseline(doc)["phase_results"], "Build")), str(t))
check("timing: baseline test from the Baseline scenario",
      near(t.get("baseline_test_s"), dur(baseline(doc)["phase_results"], "Test")), str(t))
check("timing: summed mutant build seconds", near(t.get("mutant_build_s"), exp_mb, 0.05), f"{t.get('mutant_build_s')} vs {exp_mb}")
check("timing: summed mutant test seconds", near(t.get("mutant_test_s"), exp_mt, 0.05), f"{t.get('mutant_test_s')} vs {exp_mt}")
check("timing: average per tested mutant = (build + test) / tested",
      near(t.get("avg_s_per_mutant"), (exp_mb + exp_mt) / len(rows), 0.01), str(t.get("avg_s_per_mutant")))
check("timing: five slowest, sorted, first is the true slowest",
      len(t.get("slowest", [])) == 5 and t["slowest"][0]["name"] == exp_top[0][0]
      and [s["s"] for s in t["slowest"]] == sorted([s["s"] for s in t["slowest"]], reverse=True),
      str(t.get("slowest")))
check("timing: slowest rows carry name and seconds", all(set(s) == {"name", "s"} for s in t["slowest"]), str(t["slowest"]))

# ---- unparseable or missing durations leave the field out, never crash ----
tmp = tempfile.mkdtemp()
try:
    for name in ("outcomes.json", "mutants.json", "missed.txt", "caught.txt", "timeout.txt", "unviable.txt"):
        src = os.path.join(FX, "missed", name)
        if os.path.exists(src):
            shutil.copy(src, tmp)
    bad = json.load(open(os.path.join(tmp, "outcomes.json")))
    mrows = mutant_rows(bad)
    for ph in mrows[0]["phase_results"]:
        if ph["phase"] == "Build":
            ph["duration"] = "oops"
    for ph in baseline(bad)["phase_results"]:
        if ph["phase"] == "Test":
            ph["duration"] = None
    json.dump(bad, open(os.path.join(tmp, "outcomes.json"), "w"))
    chk2, _ = M.verdict(tmp, 2, "", A, TG, wall_s=3.0)
    t2 = chk2.get("timing", {})
    check("bad durations: no crash, verdict still fail", chk2["status"] == "fail", str(chk2))
    check("bad durations: unparseable mutant build field left out", "mutant_build_s" not in t2, str(t2))
    check("bad durations: avg left out with it", "avg_s_per_mutant" not in t2, str(t2))
    check("bad durations: bad baseline test left out", "baseline_test_s" not in t2, str(t2))
    check("bad durations: wall still reported", t2.get("wall_s") == 3.0, str(t2))
    check("bad durations: good baseline build still reported", "baseline_build_s" in t2, str(t2))
finally:
    shutil.rmtree(tmp, ignore_errors=True)

# no outcomes at all (budget before the first scenario): wall only, no crash
chk3, _ = M.verdict(os.path.join(FX, "no-such-dir"), "timeout", "", A, TG, wall_s=5.0)
check("no outcomes: timing is wall only", chk3.get("timing") == {"wall_s": 5.0}, str(chk3.get("timing")))

# ---- partial confirm: one entry, stable id, text names the untested count, timing hint ----
pe = M.partial_entry({"status": "partial", "tested": 7, "total": 15})
check("partial confirm: severity confirm, class agent-fixable", pe["severity"] == "confirm" and pe["class"] == "agent-fixable", str(pe))
check("partial confirm: check R3", pe["check"] == "R3", str(pe))
check("partial confirm: problem names untested/total", pe["problem"] == "R3 partial: 8/15 mutants untested at budget", pe["problem"])
check("partial confirm: hint names timing and the fix order",
      "timing" in pe["hint"] and "diff" in pe["hint"] and "budget" in pe["hint"], pe["hint"])
check("partial confirm: forbidden", pe["forbidden"] == "treating a partial R3 as tested", pe["forbidden"])
check("partial confirm: id stable across counts and heads",
      pe["id"] == M.partial_entry({"status": "partial", "tested": 1, "total": 2})["id"] and pe["id"].startswith("R3-"),
      pe["id"])
pu = M.partial_entry({"status": "partial", "tested": 3, "total": None})
check("partial confirm: total unknown is said", "total unknown" in pu["problem"], pu["problem"])

# ---- combine: sums, recomputed average, top five across shards, per-shard wall, one partial confirm ----
s0 = {"checks": {"R3": M.verdict(os.path.join(FX, "shard-0-of-2"), 2, "", A, TG, wall_s=10.0)[0]},
      "entries": M.verdict(os.path.join(FX, "shard-0-of-2"), 2, "", A, TG, wall_s=10.0)[1]}
s1 = {"checks": {"R3": M.verdict(os.path.join(FX, "shard-1-of-2"), 2, "", A, TG, wall_s=7.5)[0]},
      "entries": M.verdict(os.path.join(FX, "shard-1-of-2"), 2, "", A, TG, wall_s=7.5)[1]}
H, B = "a" * 40, "b" * 40
for e in (s0, s1):
    e["head"], e["base"] = H, B
m = merge.combine_shards(B, H, 2, {0: s0, 1: s1}, {})
mt = m["checks"]["R3"]["timing"]
s0_b = M.verdict(os.path.join(FX, "shard-0-of-2"), 2, "", A, TG)[0]["timing"]
s1_b = M.verdict(os.path.join(FX, "shard-1-of-2"), 2, "", A, TG)[0]["timing"]
check("combine: summed mutant build", near(mt.get("mutant_build_s"), s0_b["mutant_build_s"] + s1_b["mutant_build_s"], 0.05), str(mt))
check("combine: summed mutant test", near(mt.get("mutant_test_s"), s0_b["mutant_test_s"] + s1_b["mutant_test_s"], 0.05), str(mt))
check("combine: average recomputed over all 17 tested", near(mt.get("avg_s_per_mutant"),
      (mt["mutant_build_s"] + mt["mutant_test_s"]) / 17, 0.01), str(mt))
check("combine: wall is the slowest shard (they run in parallel)", mt.get("wall_s") == 10.0, str(mt))
check("combine: per-shard wall kept", [(x["shard"], x["wall_s"]) for x in mt.get("shards", [])] == [("0/2", 10.0), ("1/2", 7.5)],
      str(mt.get("shards")))
union = sorted(s0_b.get("slowest", []) + s1_b.get("slowest", []), key=lambda x: -x["s"])[:5]
check("combine: top five across shards", [x["s"] for x in mt.get("slowest", [])] == [x["s"] for x in union], str(mt.get("slowest")))
check("combine: no partial confirm when merged is not partial", not any(e["id"] == M.partial_entry({})["id"] for e in m["entries"]))

# two shards both partial: exactly one partial confirm, merged totals
p0, pe0 = M.verdict(os.path.join(FX, "partial"), "timeout", "", A, TG, wall_s=4.0)
p1, pe1 = M.verdict(os.path.join(FX, "partial"), "timeout", "", A, TG, wall_s=4.5)
p0["status"] = p1["status"] = "partial"
envs = {0: {"head": H, "base": B, "checks": {"R3": p0}, "entries": [M.partial_entry(p0)]},
        1: {"head": H, "base": B, "checks": {"R3": p1}, "entries": [M.partial_entry(p1)]}}
mp = merge.combine_shards(B, H, 2, envs, {})
guards = [e for e in mp["entries"] if e["id"] == M.partial_entry({})["id"]]
check("two partial shards: exactly one partial confirm", len(guards) == 1, str([e["problem"] for e in mp["entries"]]))
check("two partial shards: merged status partial", mp["checks"]["R3"]["status"] == "partial", str(mp["checks"]["R3"]))
check("two partial shards: problem counts merged untested", guards and guards[0]["problem"] == "R3 partial: 16/30 mutants untested at budget",
      str(guards and guards[0]["problem"]))
check("two partial shards: merged summary is pass with one confirm", mp["summary"].startswith("pass ")
      and "(0 fail, 1 confirm;" in mp["summary"], mp["summary"])

sys.exit(1 if FAILS else 0)
PY
eq "$?" 0 "timing: fixture sums, average, slowest; bad durations left out; combine sums, per-shard wall, one partial confirm"

# ---- timing and the partial confirm through the CLI (single shard and merged) ----
PID=$(python3 -I -c "import sys; sys.path.insert(0, sys.argv[1] + '/scripts'); from mech_review import mutants as M; print(M.partial_entry({})['id'])" "$ROOT")
mrepo tpartial
out=$(MUT_FIXTURE=partial MUT_RC=0 MUT_HANG=1 mut --mutation-budget 0.02); rc=$?
eq "$rc" 0 "single partial: still exit 0"
eq "$(jq -r '[.entries[] | select(.id=="'"$PID"'")] | length' <<<"$out")" 1 "single partial: exactly one partial confirm"
eq "$(jq -r '[.entries[] | select(.id=="'"$PID"'")][0].severity' <<<"$out")" confirm "single partial: confirm, not fail"
eq "$(jq -r '[.entries[] | select(.id=="'"$PID"'")][0].problem' <<<"$out")" "R3 partial: 8/15 mutants untested at budget" "single partial: problem counts untested"
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 1 confirm; ran: R3; partial: R3 (7/15); skipped: R1 R2 R4)" "single partial: summary counts the confirm"
[[ "$(jq -r .checks.R3.timing.wall_s <<<"$out")" != null ]] && ok "single partial: wall time in checks.R3.timing" || fail "single partial: wall time in checks.R3.timing"
eq "$(jq -r '.checks.R3.timing.slowest | length' <<<"$out")" 5 "single partial: five slowest mutants"

# merged: two shards both partial -> one confirm, summed totals, per-shard wall
MG2="$T/merge2"; mkdir -p "$MG2"
MUT_FIXTURE=partial MUT_RC=0 MUT_HANG=1 mut --shard 0/2 --mutation-budget 0.02 > "$MG2/p0.json"
MUT_FIXTURE=partial MUT_RC=0 MUT_HANG=1 mut --shard 1/2 --mutation-budget 0.02 > "$MG2/p1.json"
out=$(mg 2 --envelope 0="$MG2/p0.json" --envelope 1="$MG2/p1.json"); rc=$?
eq "$rc" 0 "merged two partial: exit 0"
eq "$(jq -r '[.entries[] | select(.id=="'"$PID"'")] | length' <<<"$out")" 1 "merged two partial: exactly one partial confirm"
eq "$(jq -r '.checks.R3.timing.shards | length' <<<"$out")" 2 "merged two partial: per-shard wall for both shards"
eq "$(jq -r '.checks.R3.timing.shards[0].shard' <<<"$out")" "0/2" "merged two partial: shard label 0/2"

# ---- baseline outcomes (real cargo-mutants 27.1.0 output): a baseline Timeout is n/a, a real failure stays fail,
# a budget hit before the baseline finished is partial with 0 tested ----
python3 -I - "$ROOT" <<'PY'
import os
import sys

ROOT = sys.argv[1]
sys.path.insert(0, os.path.join(ROOT, "scripts"))
FX = os.path.join(ROOT, "tests", "fixtures", "mutants")
FAILS = 0


def check(name, cond, detail=""):
    global FAILS
    if cond:
        print(f"  ok   {name}")
    else:
        FAILS += 1
        print(f"  FAIL {name}\n       {detail}")


from mech_review import mutants as M  # noqa: E402
from mech_review.stack import RustAdapter  # noqa: E402

A = RustAdapter()
TG = ["tests/**"]

chk, ents = M.verdict(os.path.join(FX, "baseline-timeout"), 4, "", A, TG, wall_s=1.5, timeout_s=1)
check("baseline timeout: R3 n/a, not fail", chk["status"] == "n/a", str(chk))
check("baseline timeout: note names the timeout, the seconds and mutation-budget (#46: not mutant-timeout)",
      all(w in chk["note"] for w in ("timed out", "1s", "mutation-budget")) and "mutant-timeout" not in chk["note"], chk["note"])
check("baseline timeout: no fail entry", ents == [], str(ents))
check("baseline timeout: not read as baseline tests fail", "baseline tests fail" not in chk["note"], chk["note"])
chk, ents = M.verdict(os.path.join(FX, "baseline-timeout"), 4, "", A, TG, wall_s=1.5)
check("baseline timeout, seconds unknown: still n/a with mutation-budget named",
      chk["status"] == "n/a" and "mutation-budget" in chk["note"] and ents == [], str(chk))

chk, ents = M.verdict(os.path.join(FX, "baseline-failure"), 4, "", A, TG, wall_s=3.0)
check("baseline failure (real): fail, one agent-fixable baseline entry", chk["status"] == "fail" and len(ents) == 1
      and ents[0]["class"] == "agent-fixable" and "baseline" in ents[0]["problem"], str(chk))

chk, ents = M.verdict(os.path.join(FX, "baseline-budget"), "timeout", "", A, TG, wall_s=1.2)
check("budget in baseline: partial", chk["status"] == "partial", str(chk))
check("budget in baseline: 0 tested of 7", chk.get("tested") == 0 and chk.get("total") == 7, str(chk))
check("budget in baseline: note says the baseline did not finish", "baseline did not finish" in chk["note"], chk["note"])
check("budget in baseline: no verdict entries (partial confirm is added by run)", ents == [], str(ents))
chk, ents = M.verdict(os.path.join(FX, "no-such-dir"), "timeout", "", A, TG)
check("budget before any output: note says the baseline did not finish", "baseline did not finish" in chk["note"], chk["note"])

sys.exit(1 if FAILS else 0)
PY
eq "$?" 0 "baseline outcomes: timeout n/a, failure fail, budget-in-baseline partial 0 tested"

# ---- CLI: baseline timeout, budget in baseline, mutant-timeout flags, stderr tail (cargo-mutants stub) ----
mrepo basetimeout
out=$(MUT_FIXTURE=baseline-timeout MUT_RC=4 mut --mutant-timeout 1 2>"$T/bt.err"); rc=$?
eq "$rc" 0 "baseline timeout CLI: exit 0 (n/a is not a failure)"
eq "$(jq -r .checks.R3.status <<<"$out")" n/a "baseline timeout CLI: R3 n/a"
has "$(jq -r .checks.R3.note <<<"$out")" "after 1s" "baseline timeout CLI: note names the seconds"
eq "$(jq -r '[.entries[] | select(.check=="R3")] | length' <<<"$out")" 0 "baseline timeout CLI: no R3 entry"
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 0 confirm; ran: none; skipped: R1 R2 R4; n/a: R3)" "baseline timeout CLI: summary names n/a"

mrepo basebudget
out=$(MUT_FIXTURE=baseline-budget MUT_RC=0 MUT_HANG=1 mut --mutation-budget 0.02); rc=$?
eq "$rc" 0 "budget in baseline CLI: exit 0 (does not block)"
eq "$(jq -r .checks.R3.status <<<"$out")" partial "budget in baseline CLI: R3 partial"
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 1 confirm; ran: R3; partial: R3 (0/7); skipped: R1 R2 R4)" "budget in baseline CLI: summary 0/7"

mrepo mtdefault
: > "$MECH_STUB_LOG"
out=$(MUT_FIXTURE=missed MUT_RC=2 mut); rc=$?
lacks "$(cat "$MECH_STUB_LOG")" " --timeout" "mutant-timeout default: no --timeout sent (baseline unlimited)"
: > "$MECH_STUB_LOG"
out=$(MUT_FIXTURE=missed MUT_RC=2 mut --mutant-timeout auto); rc=$?
lacks "$(cat "$MECH_STUB_LOG")" " --timeout" "mutant-timeout auto: no --timeout sent"
eq "$rc" 1 "mutant-timeout auto: runs normally (exit 1 on MISSED)"
: > "$MECH_STUB_LOG"
out=$(MUT_FIXTURE=missed MUT_RC=2 mut --mutant-timeout 30); rc=$?
has "$(cat "$MECH_STUB_LOG")" "--timeout 30" "mutant-timeout 30: --timeout 30 sent"
for bad in 0 abc -5; do
  out=$(MECH_TEST_STUB="$MUT" python3 -I "$MR" mutants --repo "$R" --base "$B" --head "$H" --stack rust --mutant-timeout "$bad" 2>/dev/null); rc=$?
  eq "$rc" 2 "mutant-timeout '$bad': usage error exit 2"
done

# stderr: last 40 lines of cargo-mutants log/baseline.log on a non-pass run; stdout stays pure JSON
TF="$T/tailfx"; mkdir -p "$TF/baseline-long/log"
cp "$FX/baseline-failure/mutants.json" "$FX/baseline-failure/outcomes.json" "$TF/baseline-long/"
seq 1 100 | sed 's/^/baseline line /' > "$TF/baseline-long/log/baseline.log"
mrepo tailfail
out=$(MECH_FX="$TF" MUT_FIXTURE=baseline-long MUT_RC=4 mut 2>"$T/tail.err"); rc=$?
eq "$rc" 1 "stderr tail: baseline failure exit 1"
jq -e . <<<"$out" >/dev/null 2>&1 && ok "stderr tail: stdout is pure JSON" || fail "stderr tail: stdout is not JSON"
has "$(cat "$T/tail.err")" "baseline line 100" "stderr tail: last line of the log is printed"
has "$(cat "$T/tail.err")" "baseline line 61" "stderr tail: the last 40 lines are printed"
lacks "$(cat "$T/tail.err")" "baseline line 60" "stderr tail: only the last 40 lines"
lacks "$out" "baseline line" "stderr tail: no log text on stdout"
mrepo tailpass
out=$(MUT_FIXTURE=caught MUT_RC=0 mut 2>"$T/pass.err"); rc=$?
eq "$(wc -c < "$T/pass.err" | tr -d ' ')" 0 "stderr tail: a pass prints nothing to stderr"

# ---- combine: one entry per id across shards; an exact repeat collapses, a different entry keeps its place ----
python3 -I - "$ROOT" <<'PY'
import os
import re
import sys

ROOT = sys.argv[1]
sys.path.insert(0, os.path.join(ROOT, "scripts"))
FAILS = 0


def check(name, cond, detail=""):
    global FAILS
    if cond:
        print(f"  ok   {name}")
    else:
        FAILS += 1
        print(f"  FAIL {name}\n       {detail}")


from mech_review import merge  # noqa: E402

H, B = "a" * 40, "b" * 40


def ent(eid, line=2, problem="MISSED mutant pkg/mod.py:2:11: replace + with -"):
    return {"id": eid, "check": "R3", "class": "agent-fixable", "severity": "fail", "file": "pkg/mod.py", "line": line,
            "problem": problem, "hint": "h", "forbidden": "f"}


def env(entries):
    return {"head": H, "base": B, "checks": {"R3": {"status": "fail", "note": "1 missed", "tested": 1, "total": 1}},
            "entries": entries}


m = merge.combine_shards(B, H, 2, {0: env([ent("R3-aaaaaaaa")]), 1: env([ent("R3-aaaaaaaa")])}, {})
check("exact repeat from two shards: one entry", [e["id"] for e in m["entries"]] == ["R3-aaaaaaaa"],
      str([e["id"] for e in m["entries"]]))

m = merge.combine_shards(B, H, 2, {0: env([ent("R3-aaaaaaaa", 2, "p one")]), 1: env([ent("R3-aaaaaaaa", 9, "p two")])}, {})
ids = [e["id"] for e in m["entries"]]
check("two different entries sharing an id: both kept, ids unique", len(m["entries"]) == 2 and len(set(ids)) == 2, str(ids))
check("two different entries: ids keep the R3-<8 hex> form", all(re.fullmatch(r"R3-[0-9a-f]{8}", i) for i in ids), str(ids))
check("two different entries: both still fail", all(e["severity"] == "fail" for e in m["entries"]), str(m["entries"]))
check("note lists each shard", "shard 0/2:" in m["checks"]["R3"]["note"] and "shard 1/2:" in m["checks"]["R3"]["note"],
      m["checks"]["R3"]["note"])

m = merge.combine_shards(B, H, 2, {0: env([ent("R3-aaaaaaaa"), ent("R3-bbbbbbbb", 5, "x")]),
                                   1: env([ent("R3-aaaaaaaa")])}, {})
check("repeat within and across shards: one entry per id", len(m["entries"]) == len({e["id"] for e in m["entries"]}) == 2,
      str([e["id"] for e in m["entries"]]))

sys.exit(1 if FAILS else 0)
PY
eq "$?" 0 "combine: one entry per id; exact repeats collapse; distinct entries kept"

# crate_check: the one crate-dir check every mutation tool runs in its worktree at head
python3 -I - "$ROOT" <<'PY'
import os
import sys
import tempfile
sys.path.insert(0, sys.argv[1] + "/scripts")
from mech_review import mutants as M  # noqa: E402
from mech_review.gitio import Review  # noqa: E402
from mech_review.stack import PythonAdapter, RustAdapter  # noqa: E402

wt = tempfile.mkdtemp()
rv = lambda a, d: Review("r", "m", "h", a, [], d)
crate, bad = M.crate_check(rv(RustAdapter(), "x"), wt)
assert crate == os.path.join(wt, "x"), crate
assert bad[0] == {"status": "fail", "note": "project dir x not found at head: mutants not run"}, bad[0]
assert [(e["check"], e["class"], e["file"], e["line"]) for e in bad[1]] == [("R3", "agent-fixable", "", 0)], bad[1]
assert bad[1][0]["id"].startswith("R3-") and "_key" not in bad[1][0], bad[1]
os.mkdir(os.path.join(wt, "x"))
assert M.crate_check(rv(RustAdapter(), "x"), wt)[1] == ({"status": "n/a", "note": "no Cargo.toml in x: set project-dir"}, [])
note = M.crate_check(rv(PythonAdapter(), "x"), wt)[1][0]["note"]
assert note == "no pyproject.toml, setup.py or setup.cfg in x: set project-dir", note
open(os.path.join(wt, "x", "Cargo.toml"), "w").close()
assert M.crate_check(rv(RustAdapter(), "x"), wt) == (os.path.join(wt, "x"), None)
PY
eq "$?" 0 "crate_check: missing dir fails with one R3 entry; missing manifest n/a; ok crate passes"

done_tests
