#!/bin/bash
source "$EK_REPO/.ek/scenarios/lib.sh"
source "$EK_PARENT_DIR/fixtures/helpers.sh"
bad=0
R="$PWD/cont"; rust_repo "$R"
cat > "$R/.github/workflows/ci.yml" <<'Y'
jobs:
  test:
    steps:
      - run: |
          sudo apt-get update
          sudo apt-get install -y \
            libfoo-dev \
            libbar-dev
Y
commit "$R"
( out=$(doctor --repo "$R" --no-trial 2>"$PWD/err"); rc=$?
  hasnt "continuation traceback" "$(cat "$PWD/err")" "Traceback"
  eq "continuation exit" "$rc" 1
  eq "continuation packages" "$(jq -r '.inputs["extra-apt-packages"]' <<<"$out")" "libfoo-dev libbar-dev" ) || bad=1

Q="$PWD/quote"; rust_repo "$Q"
cat > "$Q/.github/workflows/ci.yml" <<'Y'
jobs:
  test:
    steps:
      - run: echo "sudo apt-get install -y curl"
Y
commit "$Q"
( out=$(doctor --repo "$Q" --no-trial 2>"$PWD/err"); rc=$?
  hasnt "quoted echo traceback" "$(cat "$PWD/err")" "Traceback"
  eq "quoted echo exit" "$rc" 1
  eq "quoted echo json" "$(jq -r .detected.stack <<<"$out")" rust ) || bad=1
[[ $bad == 0 ]] || exit 1
echo "workflow-crash ok"
