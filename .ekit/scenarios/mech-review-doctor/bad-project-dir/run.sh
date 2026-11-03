#!/bin/bash
source "$EKIT_REPO/.ekit/scenarios/lib.sh"
source "$EKIT_PARENT_DIR/fixtures/helpers.sh"
R="$PWD/rust"; rust_repo "$R"
for dir in ../x /etc; do
  doctor --repo "$R" --project-dir "$dir" >/dev/null 2>"$PWD/err"; rc=$?
  eq "$dir exit" "$rc" 2
  has "$dir message" "$(cat "$PWD/err")" "want a directory under the repo root"
done
doctor --repo "$R" --stack cobol >/dev/null 2>"$PWD/err"; rc=$?
eq "bad stack exit" "$rc" 2
has "bad stack message" "$(cat "$PWD/err")" "argument --stack"
hasnt "bad stack: doctor is a subcommand" "$(cat "$PWD/err")" "argument command"
doctor --repo "$R" --bogus >/dev/null 2>"$PWD/err"; rc=$?
eq "bad flag exit" "$rc" 2
has "bad flag usage" "$(cat "$PWD/err")" "mech-review.py doctor"

out=$(doctor --repo "$R" --project-dir nosuch 2>"$PWD/err"); rc=$?
eq "no such dir exit" "$rc" 1
has "no such dir problem" "$(jq -r '.entries[0].problem' <<<"$out")" "no project found"
eq "no such dir no inputs" "$(jq -c .inputs <<<"$out")" '{}'
hasnt "no such dir traceback" "$(cat "$PWD/err")" "Traceback"

D="$PWD/docs"; mkdir "$D"; git -C "$D" init -q -b main; printf 'notes\n' > "$D/README.md"; commit "$D"
out=$(doctor --repo "$D"); rc=$?
eq "no project exit" "$rc" 1
has "no project problem" "$(jq -r '.entries[0].problem' <<<"$out")" "no project found"
eq "no project no inputs" "$(jq -c .inputs <<<"$out")" '{}'
eq "nothing trial-run" "$(wc -l < "$STUB_LOG")" 0
echo "bad-project-dir ok"
