#!/bin/bash
source "$EK_REPO/.ek/scenarios/lib.sh"
source "$EK_PARENT_DIR/fixtures/helpers.sh"
mkdir "$PWD/plain"; mkdir "$PWD/empty"; git -C "$PWD/empty" init -q -b main
for target in plain nowhere empty; do
  out=$(doctor --repo "$PWD/$target" 2>"$PWD/err"); rc=$?
  err=$(cat "$PWD/err")
  eq "$target exit" "$rc" 2
  eq "$target stdout" "$out" ""
  has "$target message" "$err" "mech-review:"
  hasnt "$target traceback" "$err" "Traceback"
  hasnt "$target knows the subcommand" "$err" "invalid choice"
done
echo "not-a-repo ok"
