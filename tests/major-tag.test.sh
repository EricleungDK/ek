#!/bin/bash
# scripts/move-major-tag.sh and the release workflow that runs it: a release tag vX.Y.Z moves
# the floating major tag vX, forward only, after ekit's tests pass. Callers pin @v0 and never bump.
source "$(dirname "$0")/lib.sh"
SCRIPT="$ROOT/scripts/move-major-tag.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

git init -q --bare "$T/remote.git"
git init -q "$T/work"; cd "$T/work" || exit 1
git config user.email t@t; git config user.name t
git remote add origin "$T/remote.git"
commit() { git commit -q --allow-empty -m "$1"; git rev-parse HEAD; }
remote_sha() { git ls-remote "$T/remote.git" "refs/tags/$1" | cut -f1; }

c1=$(commit one); git tag v0.2.4
out=$(bash "$SCRIPT" v0.2.4 2>&1); rc=$?
eq "$rc" 0 "first release: exit 0"
eq "$(remote_sha v0)" "$c1" "first release: v0 created at the release commit"
has "$out" "v0 -> v0.2.4" "first release: says where v0 points"

c2=$(commit two); git tag v0.2.5
bash "$SCRIPT" v0.2.5 >/dev/null 2>&1; rc=$?
eq "$rc" 0 "next release: exit 0"
eq "$(remote_sha v0)" "$c2" "next release: v0 moves forward"

out=$(bash "$SCRIPT" v0.2.5 2>&1); rc=$?
eq "$rc" 0 "same release again: exit 0"
has "$out" "already" "same release again: a no-op that says so"

git checkout -q "$c1"; c3=$(commit hotfix-on-old); git tag v0.1.9
out=$(bash "$SCRIPT" v0.1.9 2>&1); rc=$?
eq "$rc" 3 "tag not containing v0: refused with exit 3"
eq "$(remote_sha v0)" "$c2" "tag not containing v0: v0 not moved back"
has "$out" "not moved back" "tag not containing v0: says why"

git checkout -q "$c2"; c4=$(commit major); git tag v1.0.0
bash "$SCRIPT" v1.0.0 >/dev/null 2>&1; rc=$?
eq "$rc" 0 "new major: exit 0"
eq "$(remote_sha v1)" "$c4" "new major: v1 created"
eq "$(remote_sha v0)" "$c2" "new major: v0 untouched"

out=$(bash "$SCRIPT" v0.2 2>&1); rc=$?
eq "$rc" 2 "not vX.Y.Z: usage exit 2"
out=$(bash "$SCRIPT" v0.3.0-rc1 2>&1); rc=$?
eq "$rc" 2 "pre-release tag: usage exit 2 (never moves v0)"

# a fresh clone with a stale local v0: the script reads the remote's v0, not the local one
git tag -f v0 "$c1" >/dev/null
git checkout -q "$c2"; c5=$(commit three); git tag v0.2.6
bash "$SCRIPT" v0.2.6 >/dev/null 2>&1; rc=$?
eq "$rc" 0 "stale local v0: exit 0"
eq "$(remote_sha v0)" "$c5" "stale local v0: remote v0 moves from its own position"

# the workflow: release tags only, tests before the move, plugin.json version checked
WF="$ROOT/.github/workflows/release.yml"
wf=$(cat "$WF" 2>/dev/null)
has "$wf" "'v[0-9]+.[0-9]+.[0-9]+'" "release workflow: runs on vX.Y.Z tags"
has "$wf" "contents: write" "release workflow: may push the major tag"
has "$wf" "plugin.json" "release workflow: checks the tag against plugin.json"
tests_at=$(grep -n "tests/run.sh" "$WF" | head -1 | cut -d: -f1)
move_at=$(grep -n "move-major-tag.sh" "$WF" | head -1 | cut -d: -f1)
[[ -n $tests_at && -n $move_at && $tests_at -lt $move_at ]] && ok "release workflow: tests run before the tag moves" \
  || fail "release workflow: tests run before the tag moves (tests line ${tests_at:-none}, move line ${move_at:-none})"

# callers are told to follow @v0, not to pin and bump
doc=$(cat "$ROOT/docs/mech-review-ci.md")
has "$doc" "mech-review.yml@v0" "docs: caller example uses @v0"
lacks "$doc" "Bump the tag to upgrade" "docs: no bump instruction"
has "$(cat "$ROOT/skills/ci-doctor/SKILL.md")" "mech-review.yml@v0" "ci-doctor: caller uses @v0"

done_tests
