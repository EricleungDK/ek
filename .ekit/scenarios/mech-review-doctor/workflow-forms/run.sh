#!/bin/bash
source "$EKIT_REPO/.ekit/scenarios/lib.sh"
source "$EKIT_PARENT_DIR/fixtures/helpers.sh"
bad=0
# form <name> <run step>: a repo whose CI has that step, the doctor's inputs in $PWD/<name>.json
form() { local r="$PWD/$1"; rust_repo "$r"
  printf 'jobs:\n  test:\n    steps:\n      - run: %s\n' "$2" > "$r/.github/workflows/ci.yml"; commit "$r"
  doctor --repo "$r" --no-trial > "$PWD/$1.json" 2>/dev/null; }

form matrix 'sudo apt-get install -y libfoo ${{ matrix.pkg }}'
( eq "matrix expression dropped" "$(jq -r '.inputs["extra-apt-packages"]' "$PWD/matrix.json")" "libfoo" ) || bad=1
form sysctl 'sudo sysctl vm.max_map_count=262144'
( has "sysctl without -w" "$(jq -r '.inputs["setup-command"]' "$PWD/sysctl.json")" "vm.max_map_count=262144" ) || bad=1
form rustup 'rustup default 1.86.0'
( eq "rustup pin" "$(jq -r '.inputs["rust-toolchain"]' "$PWD/rustup.json")" "1.86.0" ) || bad=1
[[ $bad == 0 ]] || exit 1
echo "workflow-forms ok"
