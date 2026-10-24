#!/bin/bash
source "$EK_REPO/.ek/scenarios/lib.sh"
command -v claude >/dev/null || fail "claude CLI missing: cannot run model check (verification debt if unavailable)"
mk_repo; install_kit
out=$(cd "$SAMPLE" && HOME="$OLDHOME" timeout 120 claude -p "List the skills available in this project whose name contains 'taste'. Reply with only the skill names, comma separated." 2>&1) \
  || fail "claude -p failed (auth/network?): $out"
has model "$out" "taste-it"
echo "model ok"
