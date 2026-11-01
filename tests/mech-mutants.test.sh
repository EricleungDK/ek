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
  case "$prev" in -o|--output) out="$a" ;; --shard) shard="$a" ;; esac
  prev="$a"
done
k=${shard%%/*}
echo "$(pwd -P) | $*" >> "$MECH_STUB_LOG"
if [[ -n "${MUT_FIXTURE-}" && -n "$out" ]]; then
  fx="${MUT_FIXTURE//\{k\}/$k}"
  mkdir -p "$out/mutants.out"; cp -r "$MECH_FX/$fx/." "$out/mutants.out/"
fi
if [[ -n "${MUT_HANG-}" ]]; then sleep 30; fi
exit "${MUT_RC:-0}"
SH
chmod +x "$MUT"

# mrepo <name> [tests-only]: base with src/lib.rs and tests/a.rs; head changes src (or only tests). sets R B H
mrepo() {
  R="$T/$1"; mkdir -p "$R/src" "$R/tests"; git -C "$R" init -q -b main
  printf 'pub fn add(a: i32, b: i32) -> i32 { a + b }\n' > "$R/src/lib.rs"
  printf '#[test]\nfn adds() {\n    assert_eq!(add(1, 2), 3);\n}\n' > "$R/tests/a.rs"
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
has "$(cat "$MECH_STUB_LOG")" "--timeout 120" "missed: per-mutant timeout 120s"
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
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 0 confirm; ran: R3; partial: R3 (7/15); skipped: R1 R2 R4)" "partial: summary names partial"
eq "$(jq -r '[.checks[] | select(.status=="pass")] | length' <<<"$out")" 0 "partial: never all pass"
[[ $SECONDS -lt 10 ]] && ok "partial: budget kill is prompt" || fail "partial: budget kill took ${SECONDS}s"

# tool not installed: n/a (env), named in the summary, never pass for R3
mrepo nocmd
out=$(env -u MECH_TEST_STUB python3 -I "$MR" mutants --repo "$R" --base "$B" --head "$H" --stack rust --test-paths 'tests/**' --mutants-cmd "ek-no-such-cargo mutants"); rc=$?
eq "$rc" 0 "not installed: exit 0 (n/a is not a failure)"
eq "$(jq -r .checks.R3.status <<<"$out")" n/a "not installed: R3 n/a"
has "$(jq -r .checks.R3.note <<<"$out")" "(env)" "not installed: note says env"
eq "$(jq -r .summary <<<"$out")" "pass $H (0 fail, 0 confirm; ran: none; skipped: R1 R2 R4; n/a: R3)" "not installed: summary names n/a"

# unexpected exit (cargo cannot find a manifest): n/a (env), not fail, not pass
mrepo nomanifest
out=$(MUT_FIXTURE= MUT_RC=1 mut); rc=$?
eq "$(jq -r .checks.R3.status <<<"$out")" n/a "unexpected exit 1: R3 n/a"

# baseline fails at head (exit 4): R3 fail, agent-fixable
mrepo base4
out=$(MUT_RC=4 mut); rc=$?
eq "$rc" 1 "baseline fails: exit 1"
eq "$(jq -r .checks.R3.status <<<"$out")" fail "baseline fails: R3 fail"

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

done_tests
