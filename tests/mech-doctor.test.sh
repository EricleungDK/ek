#!/bin/bash
# mech-review doctor (#39): detect stack + project dir, read CI, trial-run via the runner seam, report exact inputs. Writes nothing.
source "$(dirname "$0")/lib.sh"
MR="$ROOT/scripts/mech-review.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

mkrepo() { local r="$T/$1"; mkdir -p "$r"; git -C "$r" init -q -b main; echo "$r"; }
put() { mkdir -p "$(dirname "$1/$2")"; cat > "$1/$2"; }
commit() { git -C "$1" add -A; git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm "$2"; }
q() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }

STUB="$T/stub.sh"
cat > "$STUB" <<'SH'
#!/bin/bash
case "${MECH_STUB_RESULT:-pass}" in
  pass) printf 'test a ... ok\n\ntest result: ok. 3 passed; 0 failed; 0 ignored\n'; exit 0 ;;
  bwrap) printf 'bwrap: setting up uid map: Permission denied\ntest a ... FAILED\n\ntest result: FAILED. 2 passed; 1 failed\n'; exit 101 ;;
  fail) printf 'test a ... FAILED\n\ntest result: FAILED. 2 passed; 1 failed\n'; exit 101 ;;
esac
SH
chmod +x "$STUB"
doctor() { MECH_TEST_STUB="$STUB" python3 -I "$MR" doctor "$@"; }

# Alfredo's shape: crate in a subdir, sysctl and apt in existing CI, no hint given
A="$(mkrepo alfredo)"
echo '[package]' | put "$A" alfredo-tui/Cargo.toml
echo '[package]' | put "$A" alfredo-tui/tests/fixtures/x/Cargo.toml
echo 'fn main() {}' | put "$A" alfredo-tui/src/main.rs
put "$A" .github/workflows/rust-terminal.yml <<'Y'
jobs:
  checks:
    steps:
      - uses: dtolnay/rust-toolchain@stable
        with:
          toolchain: 1.96.0
      - run: |
          sudo apt-get update
          sudo apt-get install --yes bubblewrap util-linux
          # Ubuntu 24.04 AppArmor blocks unprivileged user namespaces that bwrap needs.
          sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 || true
          bwrap --ro-bind / / --unshare-user true
Y
commit "$A" base
out="$(doctor --repo "$A")"; rc=$?
eq "$rc" 1 "no caller: exit 1"
eq "$(q "d['detected']['stack']" <<<"$out")" rust "alfredo: stack found"
eq "$(q "d['detected']['project_dir']" <<<"$out")" alfredo-tui "alfredo: project dir found, fixture manifest ignored"
eq "$(q "d['inputs']['project-dir']" <<<"$out")" alfredo-tui "alfredo: project-dir input"
eq "$(q "d['inputs']['extra-apt-packages']" <<<"$out")" "bubblewrap util-linux" "alfredo: apt input"
eq "$(q "d['inputs']['setup-command']" <<<"$out")" "sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0" "alfredo: sysctl input, no || true"
eq "$(q "d['inputs']['rust-toolchain']" <<<"$out")" 1.96.0 "alfredo: toolchain input"
eq "$(q "d['inputs']['test-paths']" <<<"$out")" "alfredo-tui/tests/**" "alfredo: test-paths under the project dir"
eq "$(q "d['trial']['tests']" <<<"$out")" pass "trial: tests ran through the seam"
has "$(q "[e['class'] for e in d['entries']]" <<<"$out")" "needs-human" "no caller: needs-human, a person merges CI"
has "$(q "d['entries'][0]['problem']" <<<"$out")" "no mech-review caller" "no caller: named"

# deterministic, and writes nothing
again="$(doctor --repo "$A")"
eq "$again" "$out" "same output on a second run"
eq "$(git -C "$A" status --porcelain)" "" "tree untouched"
eq "$(git -C "$A" worktree list | wc -l | tr -d ' ')" 1 "trial worktree removed"

# caller missing inputs: each problem names the exact input
put "$A" .github/workflows/mech-review.yml <<'Y'
jobs:
  mech-review:
    uses: EricleungDK/ek/.github/workflows/mech-review.yml@v0.2.2
    with:
      stack: rust
      test-paths: |
        alfredo-tui/tests/**
Y
commit "$A" caller
out="$(doctor --repo "$A")"; rc=$?
eq "$rc" 1 "caller gaps: exit 1"
hints="$(q "' / '.join(e['hint'] for e in d['entries'])" <<<"$out")"
has "$hints" "project-dir: alfredo-tui" "gap: project-dir, exact"
has "$hints" "extra-apt-packages: bubblewrap util-linux" "gap: apt, exact"
has "$hints" "setup-command: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0" "gap: setup-command, exact"
has "$hints" "rust-toolchain: 1.96.0" "gap: toolchain, exact"
lacks "$hints" "stack:" "stack already right: no entry"

# complete caller: clean
put "$A" .github/workflows/mech-review.yml <<'Y'
jobs:
  mech-review:
    uses: EricleungDK/ek/.github/workflows/mech-review.yml@v0.2.2
    with:
      stack: rust
      rust-toolchain: 1.96.0
      project-dir: alfredo-tui
      test-paths: |
        alfredo-tui/tests/**
      extra-apt-packages: bubblewrap util-linux tree
      # comment
      setup-command: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
Y
commit "$A" full
out="$(doctor --repo "$A")"; rc=$?
eq "$rc" 0 "complete caller: exit 0"
eq "$(q "len(d['entries'])" <<<"$out")" 0 "complete caller: no entries (extra packages kept)"
has "$(q "d['summary']" <<<"$out")" "ok " "complete caller: summary ok"

# trial: a sandbox failure names the input, a plain failure stays an env problem, nothing guessed
out="$(MECH_STUB_RESULT=bwrap doctor --repo "$A")"; rc=$?
eq "$rc" 1 "bwrap trial: exit 1"
eq "$(q "d['trial']['tests']" <<<"$out")" fail "bwrap trial: verdict"
has "$(q "d['entries'][0]['hint']" <<<"$out")" "extra-apt-packages" "bwrap trial: names the input"
out="$(MECH_STUB_RESULT=fail doctor --repo "$A")"; rc=$?
eq "$rc" 1 "failing tests: exit 1"
has "$(q "d['entries'][0]['problem']" <<<"$out")" "tests fail at head" "failing tests: named"

# --no-trial: static only
out="$(MECH_STUB_RESULT=fail doctor --repo "$A" --no-trial)"; rc=$?
eq "$rc" 0 "no-trial: nothing run"
eq "$(q "d['trial']['tests']" <<<"$out")" skipped "no-trial: skipped"

# missing tool: env, names setup-command
out="$(env -u MECH_TEST_STUB PATH="$(dirname "$(command -v git)")" python3 -I "$MR" doctor --repo "$A" 2>&1)"; rc=$?
if command -v cargo >/dev/null; then ok "skip: cargo present"; else
  eq "$(q "d['trial']['tests']" <<<"$out")" env "absent toolchain: env"
  has "$(q "d['entries'][0]['hint']" <<<"$out")" "setup-command" "absent toolchain: names the input"
fi

# python at the root
P="$(mkrepo py)"
echo '[project]' | put "$P" pyproject.toml
echo 'x = 1' | put "$P" pkg/a.py
commit "$P" base
out="$(doctor --repo "$P" --no-trial)"
eq "$(q "d['detected']['stack']" <<<"$out")" python "python: stack"
eq "$(q "d['detected']['project_dir']" <<<"$out")" . "python: root dir"
eq "$(q "d['inputs']['test-paths']" <<<"$out")" "tests/**" "python: test-paths at the root"
eq "$(q "'project-dir' in d['inputs']" <<<"$out")" False "python: default project-dir left out"

# ts nested
J="$(mkrepo ts)"
echo '{"devDependencies":{"vitest":"1"}}' | put "$J" web/package.json
commit "$J" base
out="$(doctor --repo "$J" --no-trial)"
eq "$(q "d['detected']['stack']" <<<"$out")" ts "ts: stack"
eq "$(q "d['detected']['project_dir']" <<<"$out")" web "ts: project dir"

# two candidates: asks, the flag settles it
M="$(mkrepo mixed)"
echo '[package]' | put "$M" api/Cargo.toml
echo '{}' | put "$M" web/package.json
commit "$M" base
out="$(doctor --repo "$M" --no-trial)"; rc=$?
eq "$rc" 1 "ambiguous: exit 1"
has "$(q "d['entries'][0]['hint']" <<<"$out")" "--project-dir" "ambiguous: names the flag"
has "$(q "d['entries'][0]['problem']" <<<"$out")" "rust in api" "ambiguous: lists candidates"
out="$(doctor --repo "$M" --no-trial --project-dir web)"
eq "$(q "d['detected']['stack']" <<<"$out")" ts "flag settles the stack"

# no project at all
N="$(mkrepo none)"; echo hi | put "$N" README.md; commit "$N" base
out="$(doctor --repo "$N" --no-trial)"; rc=$?
eq "$rc" 1 "no manifest: exit 1"
has "$(q "d['entries'][0]['problem']" <<<"$out")" "no project" "no manifest: named"

done_tests
