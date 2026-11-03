#!/bin/bash
source "$EKIT_REPO/.ekit/scenarios/lib.sh"
source "$EKIT_SCENARIO_DIR/fixtures/helpers.sh"
export TMPDIR="$PWD/tmp"; mkdir -p "$TMPDIR"

# 2. no hints, no trial: detection, workflow read, one entry that repeats the inputs, nothing run
R="$PWD/rust"; rust_repo "$R"
out=$(doctor --repo "$R" --no-trial); rc=$?
eq "first run exit" "$rc" 1
eq "detected" "$(jq -c .detected <<<"$out")" '{"stack":"rust","project_dir":"crates/app"}'
eq "inputs" "$(jq -c .inputs <<<"$out")" "$RUST_INPUTS"
eq "trial skipped" "$(jq -r .trial.tests <<<"$out")" skipped
eq "one entry" "$(jq -r '.entries|length' <<<"$out")" 1
eq "entry class" "$(jq -r '.entries[0].class' <<<"$out")" needs-human
has "entry names the caller" "$(jq -r '.entries[0].hint' <<<"$out")" "EricleungDK/ekit/.github/workflows/mech-review.yml@v0"
has "entry repeats the inputs" "$(jq -r '.entries[0].hint' <<<"$out")" '"rust-toolchain": "1.96.0"'
eq "--no-trial runs nothing" "$(wc -l < "$STUB_LOG")" 0

# 3. the caller the doctor asked for: no problems
caller "$R" <<<"$GOOD_WITH"
H=$(git -C "$R" rev-parse HEAD)
out=$(doctor --repo "$R"); rc=$?
eq "good caller exit" "$rc" 0
eq "good caller summary" "$(jq -r .summary <<<"$out")" "ok $H"
eq "good caller head" "$(jq -r .head <<<"$out")" "$H"
eq "tests verdict" "$(jq -r .trial.tests <<<"$out")" pass
eq "tool verdict" "$(jq -r .trial.mutation_tool <<<"$out")" present
eq "no entries" "$(jq -r '.entries|length' <<<"$out")" 0
tests_at=$(grep ':: test$' "$STUB_LOG" | head -1 | sed 's/ :: .*//')
[[ "$tests_at" == */crates/app ]] || fail "tests ran in [$tests_at], want the project dir"
[[ "$tests_at" != "$R"* ]] || fail "tests ran in the repo, not a throwaway worktree: [$tests_at]"

# 4. wrong caller: one exact fix per input
W="$PWD/wrong"; rust_repo "$W"
caller "$W" <<<"${GOOD_WITH/project-dir: crates\/app/project-dir: crates/old}"
sed -i 's/rust-toolchain: 1.96.0/rust-toolchain: stable/' "$W/.github/workflows/mech-review.yml"; commit "$W"
out=$(doctor --repo "$W"); rc=$?
eq "wrong caller exit" "$rc" 1
eq "wrong caller entries" "$(jq -r '.entries|length' <<<"$out")" 2
hints=$(jq -r '[.entries[].hint]|sort|join("; ")' <<<"$out")
eq "wrong caller fixes" "$hints" "set project-dir: crates/app; set rust-toolchain: 1.96.0"

# 5. tests fail at HEAD: a verdict and an entry
out=$(STUB_TESTS=fail doctor --repo "$R"); rc=$?
eq "failing tests exit" "$rc" 1
eq "failing tests verdict" "$(jq -r .trial.tests <<<"$out")" fail
has "failing tests entry" "$(jq -r '.entries[0].problem' <<<"$out")" 'cargo test'

# 6. python at the root, ts in a subdir, no hints
P="$PWD/py"; mkdir -p "$P/src/calc" "$P/tests"; git -C "$P" init -q -b main
printf '[project]\nname = "calc"\nversion = "0.0.1"\n' > "$P/pyproject.toml"
printf 'def add(a, b):\n    return a + b\n' > "$P/src/calc/core.py"; printf 'def test_add():\n    pass\n' > "$P/tests/test_core.py"
commit "$P"
out=$(doctor --repo "$P"); rc=$?
eq "python detected" "$(jq -c .detected <<<"$out")" '{"stack":"python","project_dir":"."}'
eq "python inputs" "$(jq -c .inputs <<<"$out")" '{"stack":"python","test-paths":"tests/**"}'
eq "python trial" "$(jq -c .trial <<<"$out")" '{"tests":"pass","command":"python3 -m pytest","mutation_tool":"present"}'
T="$PWD/ts"; mkdir -p "$T/web/src" "$T/web/tests"; git -C "$T" init -q -b main
printf '{"name":"w","version":"0.0.1","devDependencies":{"vitest":"3.0.0"}}\n' > "$T/web/package.json"
printf 'export const add = (a: number, b: number) => a + b\n' > "$T/web/src/a.ts"; printf 'it("x", () => {})\n' > "$T/web/tests/a.test.ts"
commit "$T"
out=$(doctor --repo "$T"); rc=$?
eq "ts detected" "$(jq -c .detected <<<"$out")" '{"stack":"ts","project_dir":"web"}'
eq "ts inputs" "$(jq -c .inputs <<<"$out")" '{"stack":"ts","project-dir":"web","test-paths":"web/tests/**"}'
eq "ts tests verdict" "$(jq -r .trial.tests <<<"$out")" pass

# 7. two crates: never a guess; --project-dir settles it
M2="$PWD/mono"; mkdir -p "$M2/a/src" "$M2/b/src"; git -C "$M2" init -q -b main
for c in a b; do printf '[package]\nname = "%s"\nversion = "0.1.0"\n' "$c" > "$M2/$c/Cargo.toml"; : > "$M2/$c/src/lib.rs"; done
commit "$M2"
out=$(doctor --repo "$M2" --no-trial); rc=$?
eq "two crates exit" "$rc" 1
eq "two crates no inputs" "$(jq -c .inputs <<<"$out")" '{}'
has "two crates named" "$(jq -r '.entries[0].problem' <<<"$out")" "several projects: rust in a, rust in b"
out=$(doctor --repo "$M2" --no-trial --project-dir b)
eq "settled" "$(jq -c .detected <<<"$out")" '{"stack":"rust","project_dir":"b"}'

# 8. deterministic, reads HEAD, leaves a dirty repo exactly as it was
printf 'broken(\n' >> "$R/crates/app/src/lib.rs"; printf 'mine\n' > "$R/untracked.txt"
before=$(snapshot "$R"; git -C "$R" diff)
doctor --repo "$R" > "$PWD/one.json"; rc=$?
doctor --repo "$R" > "$PWD/two.json"
eq "dirty tree does not change the verdict" "$rc" 0
cmp -s "$PWD/one.json" "$PWD/two.json" || fail "two runs differ: $(diff "$PWD/one.json" "$PWD/two.json")"
eq "git state unchanged" "$(snapshot "$R"; git -C "$R" diff)" "$before"
eq "one worktree" "$(git -C "$R" worktree list | wc -l)" 1
eq "no temp dir left" "$(ls "$TMPDIR" | wc -l)" 0
echo "mech-review-doctor ok"
