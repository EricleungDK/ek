source "$(dirname "$0")/lib.sh"
SC="$ROOT/scripts/scenarios.py"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export EK_STATE="$T/state"

R="$T/repo"; mkdir -p "$R"; git -C "$R" init -q
git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
sc() { (cd "$R" && python3 -I "$SC" "$@"); }
mk() { mkdir -p "$R/.ek/scenarios/$1"; printf '%s\n' "$2" > "$R/.ek/scenarios/$1/run.sh"; echo "# $1" > "$R/.ek/scenarios/$1/SCENARIO.md"; }

# none found → 2 with layout
out="$(sc run 2>&1)"; rc=$?
eq "$rc" "2" "no scenarios → exit 2"
has "$out" ".ek/scenarios/<slug>/SCENARIO.md" "none → layout shown"
has "$out" "run.sh" "none → run.sh shown"

# pass / fail
mk good 'echo hi'
out="$(sc run)"; rc=$?
eq "$rc" "0" "all pass → exit 0"
has "$out" "PASS good" "PASS line"
mk bad 'echo oops >&2; exit 3'
out="$(sc run)"; rc=$?
eq "$rc" "1" "any fail → exit 1"
has "$out" "FAIL bad: exit 3" "FAIL line with reason"
has "$out" "PASS good" "PASS still listed"

# fresh temp cwd + env
rm -rf "$R/.ek"
mk env 'pwd > "$EK_REPO/../pwd.out"; echo "$EK_REPO|$EK_SCENARIO_DIR|[$EK_PARENT_DIR]" > "$EK_REPO/../env.out"'
sc run >/dev/null
eq "$(cat "$T/env.out")" "$R|$R/.ek/scenarios/env|[]" "env: repo, scenario dir, empty parent"
cwd="$(cat "$T/pwd.out")"
[[ "$cwd" != "$R"* && "$cwd" != "$R/.ek"* ]] && ok "cwd outside repo" || fail "cwd outside repo ($cwd)"
[[ -e "$cwd" ]] && fail "temp cwd removed" || ok "temp cwd removed"

# missing document
mkdir -p "$R/.ek/scenarios/nodoc"; echo 'true' > "$R/.ek/scenarios/nodoc/run.sh"
out="$(sc run)"; rc=$?
eq "$rc" "1" "missing doc → exit 1"
has "$out" "FAIL nodoc: missing SCENARIO.md — document it (story, covers, steps, expected)" "missing doc reason"
rm -rf "$R/.ek/scenarios/nodoc"

# results + transcripts
rm -rf "$R/.ek"; mk good 'echo out-line; echo err-line >&2'; mk bad 'echo b; exit 4'
sc run >/dev/null
TH="$(sc tree-hash)"
key="$(printf %s "$(realpath "$R")" | sha1sum | cut -c1-12)"
RJ="$EK_STATE/scenarios/$key/results.json"
eq "$(jq -r .verdict "$RJ")" "FAIL" "results verdict"
eq "$(jq -r .tree "$RJ")" "$TH" "results tree == tree-hash"
eq "$(jq -r .repo "$RJ")" "$(realpath "$R")" "results repo"
eq "$(jq -r '.scenarios[]|select(.id=="bad").exit' "$RJ")" "4" "results exit"
eq "$(jq -r '.scenarios[]|select(.id=="good").duration|type' "$RJ")" "number" "results duration"
eq "$(jq -r '.scenarios[]|select(.id=="bad").reason' "$RJ")" "exit 4" "results reason on fail"
eq "$(jq -r '.scenarios[]|select(.id=="good").reason' "$RJ")" "null" "no reason on pass"
tr="$(jq -r '.scenarios[]|select(.id=="good").transcript' "$RJ")"
eq "$tr" "$EK_STATE/scenarios/$key/$TH/good.log" "transcript path"
c="$(cat "$tr")"
has "$c" "out-line" "transcript stdout"
has "$c" "err-line" "transcript stderr"
has "$c" "bash run.sh" "transcript command"
has "$c" "exit: 0" "transcript exit code"
has "$c" "cwd:" "transcript cwd"
mk sub/deep 'true'
sc run >/dev/null
[[ -f "$EK_STATE/scenarios/$key/$(sc tree-hash)/sub__deep.log" ]] && ok "id slash → __ in transcript" || fail "id slash → __ in transcript"
eq "$(sc tree-hash)" "$(sc tree-hash)" "hash stable after run"

# tree hash
rm -rf "$R/.ek"; mk good true; git -C "$R" add -A; git -C "$R" -c user.email=t@t -c user.name=t commit -qm s
h0="$(sc tree-hash)"; eq "$h0" "$(sc tree-hash)" "clean hash stable"
echo a > "$R/new.txt"; h1="$(sc tree-hash)"; [[ "$h1" != "$h0" ]] && ok "untracked add changes hash" || fail "untracked add changes hash"
echo b > "$R/new.txt"; h2="$(sc tree-hash)"; [[ "$h2" != "$h1" ]] && ok "untracked edit changes hash" || fail "untracked edit changes hash"
echo c >> "$R/.ek/scenarios/good/run.sh"; h3="$(sc tree-hash)"; [[ "$h3" != "$h2" ]] && ok "scenario edit changes hash" || fail "scenario edit changes hash"
git -C "$R" checkout -q .ek; rm "$R/new.txt"; eq "$(sc tree-hash)" "$h0" "revert → original hash"
echo z >> "$R/.ek/scenarios/good/SCENARIO.md"; git -C "$R" add -A; h4="$(sc tree-hash)"
[[ "$h4" != "$h0" ]] && ok "tracked edit changes hash" || fail "tracked edit changes hash"
git -C "$R" reset -q --hard
N="$T/nocommit"; mkdir -p "$N"; git -C "$N" init -q; echo x > "$N/f"
[[ -n "$(cd "$N" && python3 -I "$SC" tree-hash)" ]] && ok "hash works with no commits" || fail "hash works with no commits"

# check
rm -rf "$R/.ek" "$EK_STATE"; out="$(sc check)"; eq "$?" "2" "check no scenarios → 2"
mk good true
out="$(sc check)"; eq "$?" "1" "check no results → 1"; has "$out" "no results" "check reason: no results"
sc run >/dev/null; out="$(sc check)"; eq "$?" "0" "check fresh PASS → 0"
echo q >> "$R/.ek/scenarios/good/run.sh"
out="$(sc check)"; eq "$?" "1" "check stale → 1"; has "$out" "stale" "check reason: stale"
mk bad 'exit 1'; sc run >/dev/null
out="$(sc check)"; eq "$?" "1" "check FAIL → 1"; has "$out" "FAIL" "check reason: last run FAIL"

# --repo
out="$(cd "$T" && python3 -I "$SC" --repo "$R" tree-hash)"; eq "$out" "$(sc tree-hash)" "--repo override"

# hash: dangling symlink must not blind untracked edits
git -C "$R" reset -q --hard; rm -rf "$R/.ek"; mkdir -p "$R/.ek/scenarios/a"; echo 1 > "$R/.ek/scenarios/a/f"; ln -s nowhere "$R/dang"
h0="$(sc tree-hash)"; echo 2 > "$R/.ek/scenarios/a/f"
[[ "$(sc tree-hash)" != "$h0" ]] && ok "dangling symlink: untracked edit still changes hash" || fail "dangling symlink: untracked edit still changes hash"
ln -sfn elsewhere "$R/dang"; h1="$(sc tree-hash)"; ln -sfn other "$R/dang"
[[ "$(sc tree-hash)" != "$h1" ]] && ok "symlink target change changes hash" || fail "symlink target change changes hash"
rm -rf "$R/.ek" "$R/dang" "$EK_STATE"

# scenario writing into repo → FAIL
mk dirty 'echo x > "$EK_REPO/junk.txt"'
out="$(sc run)"; rc=$?
eq "$rc" "1" "repo-modifying scenario → exit 1"
has "$out" "scenarios modified the repo: run in the temp cwd" "modified-repo reason"
out="$(sc check)"; eq "$?" "1" "check after modifying run → 1"; has "$out" "FAIL" "check says last run FAIL"
rm -rf "$R/.ek" "$R/junk.txt"

# --repo without value
out="$(python3 -I "$SC" --repo 2>&1)"; rc=$?
eq "$rc" "2" "--repo no value → exit 2"; has "$out" "usage" "--repo no value → usage"; lacks "$out" "Traceback" "no traceback"

# nesting, parent first, parent env
mk a 'echo a >> "$EK_STATE/order"'; mk a/b 'echo "b:$EK_PARENT_DIR" >> "$EK_STATE/order"'; mk a-x 'echo ax >> "$EK_STATE/order"'; mk c 'true'
mk a/b/d 'echo "d:$EK_PARENT_DIR" >> "$EK_STATE/order"'
mkdir -p "$EK_STATE"; rm -f "$EK_STATE/order"
out="$(sc run)"; rc=$?
eq "$rc" "0" "nested all pass"
has "$out" "PASS a/b/d" "nested id listed"
eq "$(head -1 "$EK_STATE/order")" "a" "parent runs first"
has "$(cat "$EK_STATE/order")" "b:$R/.ek/scenarios/a" "child gets parent dir"
has "$(cat "$EK_STATE/order")" "d:$R/.ek/scenarios/a/b" "grandchild gets parent dir"

# filter
rm -f "$EK_STATE/order"
out="$(sc run a)"; rc=$?
eq "$rc" "0" "filter pass → 0"
has "$out" "PASS a/b" "filter includes child"; has "$out" "PASS a/b/d" "filter includes grandchild"
lacks "$out" "a-x" "filter excludes sibling prefix"; lacks "$out" "PASS c" "filter excludes others"
out="$(sc run a/b)"; grep -qx "PASS a" <<<"$out" && fail "filter child excludes parent" || ok "filter child excludes parent"
out="$(sc run nope)"; rc=$?
eq "$rc" "2" "unknown id → 2"; has "$out" "nope" "unknown id named"
sc run a >/dev/null
out="$(sc check)"; eq "$?" "1" "check rejects filtered run"; has "$out" "partial run" "check reason: partial run"
sc run >/dev/null; out="$(sc check)"; eq "$?" "0" "full run after partial → check 0"
rm -rf "$R/.ek"

# timeout
mk hang 'sleep 30 & echo $! > "$EK_STATE/childpid"; sleep 30'
t0=$SECONDS; out="$(EK_SCENARIO_TIMEOUT=1 sc run)"; rc=$?
eq "$rc" "1" "timeout → exit 1"; has "$out" "FAIL hang: timeout" "timeout reason"
(( SECONDS - t0 < 10 )) && ok "timeout is prompt" || fail "timeout is prompt"
sleep 0.3; kill -0 "$(cat "$EK_STATE/childpid")" 2>/dev/null && fail "timeout kills process group" || ok "timeout kills process group"
rm -rf "$R/.ek"

# can-fail
git -C "$R" reset -q --hard; git -C "$R" clean -qfd; rm -rf "$R/.ek"
echo v1 > "$R/feat.txt"; git -C "$R" add -A; git -C "$R" -c user.email=t@t -c user.name=t commit -qm base
BASE="$(git -C "$R" rev-parse HEAD)"
echo v2 > "$R/feat.txt"
mk detects 'grep -q v2 "$EK_REPO/feat.txt"'; mk blind 'test -f "$EK_REPO/feat.txt"'
sc run >/dev/null; cp "$EK_STATE/scenarios/$key/results.json" "$T/before.json"
out="$(sc can-fail "$BASE")"; rc=$?
eq "$rc" "1" "can-fail flagged → 1"
has "$out" "CAN-FAIL ✓ detects" "can-fail ✓ line"
has "$out" "CANNOT FAIL blind: passes on baseline $BASE" "cannot-fail line"
eq "$(git -C "$R" worktree list | wc -l)" "1" "worktree removed"
eq "$(cat "$EK_STATE/scenarios/$key/results.json")" "$(cat "$T/before.json")" "main results untouched"
rm -rf "$R/.ek/scenarios/blind"
out="$(sc can-fail "$BASE")"; eq "$?" "0" "can-fail all good → 0"
out="$(sc can-fail nosuchref 2>&1)"; eq "$?" "2" "bad ref → 2"
eq "$(git -C "$R" worktree list | wc -l)" "1" "no worktree left after bad ref"
mk slow 'sleep 30'
out="$(EK_SCENARIO_TIMEOUT=1 sc can-fail "$BASE")"
eq "$(git -C "$R" worktree list | wc -l)" "1" "worktree removed after timeout"

# results live with the repo (no EK_STATE): sandbox-shaped read-only HOME, and hook env (CLAUDE_PLUGIN_DATA) ≠ Bash env
D="$T/def"; mkdir -p "$D/home" "$D/.ek/scenarios/ok"; git -C "$D" init -q; echo /home/ > "$D/.gitignore"
echo true > "$D/.ek/scenarios/ok/run.sh"; echo "# ok" > "$D/.ek/scenarios/ok/SCENARIO.md"
git -C "$D" add -A; git -C "$D" -c user.email=t@t -c user.name=t commit -qm init
chmod 555 "$D/home"
dsc() { (cd "$D" && env -u EK_STATE -u CLAUDE_PLUGIN_DATA HOME="$D/home" python3 -I "$SC" "$@"); }
out="$(dsc run 2>&1)"; rc=$?
eq "$rc" "0" "read-only HOME → run still exit 0"
lacks "$out" "Error" "read-only HOME → no traceback"
eq "$(dsc check; echo $?)" "0" "read-only HOME → check fresh PASS"
eq "$(cd "$D" && env -u EK_STATE CLAUDE_PLUGIN_DATA="$T/pdata" HOME="$T/home2" python3 -I "$SC" check; echo $?)" "0" "hook env (CLAUDE_PLUGIN_DATA, other HOME) sees runner PASS"
[[ -f "$D/.git/ek/results.json" ]] && ok "results under .git/ek" || fail "results under .git/ek"
eq "$(git -C "$D" status --porcelain)" "" "results not in git status"
chmod 755 "$D/home"

# sandbox (bwrap) mounts /dev/null over absent config paths (.mcp.json, .zshrc…): must not change the tree hash
if command -v bwrap >/dev/null && bwrap --bind / / true 2>/dev/null; then
  h1="$(dsc tree-hash)"
  h2="$(cd "$D" && bwrap --bind / / --dev /dev --ro-bind /dev/null "$D/.mcp.json" env -u EK_STATE python3 -I "$SC" tree-hash)"
  rm -f "$D/.mcp.json"
  eq "$h2" "$h1" "sandbox /dev/null mounts ignored by tree hash"
else ok "sandbox /dev/null mounts ignored by tree hash (skipped: no bwrap)"; fi

done_tests
