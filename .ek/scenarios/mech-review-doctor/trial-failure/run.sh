#!/bin/bash
source "$EK_REPO/.ek/scenarios/lib.sh"
source "$EK_PARENT_DIR/fixtures/helpers.sh"
export TMPDIR="$PWD/tmp"; mkdir -p "$TMPDIR"
R="$PWD/rust"; rust_repo "$R"; caller "$R" <<<"$GOOD_WITH"
before=$(snapshot "$R")

out=$(MECH_TEST_STUB="$PWD/no-such-tool" python3 -I "$MR" doctor --repo "$R" 2>"$PWD/err"); rc=$?
eq "no toolchain exit" "$rc" 1
eq "no toolchain verdict" "$(jq -r .trial.tests <<<"$out")" env
eq "no toolchain class" "$(jq -r '.entries[0].class' <<<"$out")" env
has "no toolchain names it" "$(jq -r '.entries[0].problem' <<<"$out")" '`cargo` not found'
has "no toolchain names the input" "$(jq -r '.entries[0].hint' <<<"$out")" "setup-command"
hasnt "no toolchain traceback" "$(cat "$PWD/err")" "Traceback"

printf '#!/bin/bash\nexit 7\n' > "$R/.git/hooks/post-checkout"; chmod +x "$R/.git/hooks/post-checkout"
out=$(doctor --repo "$R" 2>"$PWD/err"); rc=$?
eq "no worktree exit" "$rc" 1
eq "no worktree verdict" "$(jq -r .trial.tests <<<"$out")" unavailable
eq "no worktree class" "$(jq -r '.entries[0].class' <<<"$out")" env
has "no worktree entry" "$(jq -r '.entries[0].problem' <<<"$out")" "trial could not run"
eq "no worktree inputs kept" "$(jq -c .inputs <<<"$out")" "$RUST_INPUTS"
hasnt "no worktree traceback" "$(cat "$PWD/err")" "Traceback"
eq "git state unchanged" "$(snapshot "$R")" "$before"
eq "no temp dir left" "$(ls "$TMPDIR" | wc -l)" 0
echo "trial-failure ok"
