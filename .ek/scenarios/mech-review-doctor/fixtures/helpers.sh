# shared by mech-review-doctor and its children (sourced after lib.sh). Installs the kit by cloning it.
git clone -q "$EK_REPO" "$PWD/kit" 2>/dev/null || fail "clone of the kit failed"
MR="$PWD/kit/scripts/mech-review.py"
export STUB_LOG="$PWD/stub.log"; : > "$STUB_LOG"
# stands in for cargo, python3, vitest and the mutation tool (MECH_TEST_STUB): STUB_TESTS=fail, STUB_TOOL=broken
STUB="$PWD/fake-tool.sh"
cat > "$STUB" <<'S'
#!/bin/bash
echo "$PWD :: $*" >> "$STUB_LOG"
if [[ "$*" == *--version* ]]; then
  if [[ "${STUB_TOOL:-ok}" == broken ]]; then echo "tool: cannot start" >&2; exit 1; fi
  echo "tool 1.0.0"; exit 0
fi
if [[ "${STUB_TESTS:-pass}" == fail ]]; then echo "test result: FAILED. 0 passed; 1 failed"; exit 101; fi
echo "test result: ok. 1 passed; 0 failed"; echo "1 passed in 0.01s"; echo "Tests  1 passed (1)"
S
chmod +x "$STUB"
doctor() { MECH_TEST_STUB="$STUB" python3 -I "$MR" doctor "$@"; }
commit() { git -C "$1" add -A; git -C "$1" commit -qm "${2:-c}"; }
# rust_repo <dir>: a crate in crates/app, one CI workflow with apt, sysctl and a toolchain pin, no mech-review caller
rust_repo() { mkdir -p "$1/crates/app/src" "$1/crates/app/tests" "$1/.github/workflows"; git -C "$1" init -q -b main
  printf '[package]\nname = "app"\nversion = "0.1.0"\nedition = "2021"\n' > "$1/crates/app/Cargo.toml"
  printf 'pub fn add(a: i32, b: i32) -> i32 { a + b }\n' > "$1/crates/app/src/lib.rs"
  printf '#[test]\nfn adds() {\n    assert_eq!(app::add(1, 2), 3);\n}\n' > "$1/crates/app/tests/a.rs"
  cat > "$1/.github/workflows/ci.yml" <<'Y'
name: ci
on: push
jobs:
  test:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@1.96.0
      - run: sudo apt-get update && sudo apt-get install -y libseccomp-dev bubblewrap
      - run: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
      - run: cargo test
        working-directory: crates/app
Y
  commit "$1" base; }
# caller <dir> <with: lines, stdin>: the mech-review caller workflow
caller() { { printf 'name: mech-review\non: pull_request\njobs:\n  mech-review:\n    uses: EricleungDK/ek/.github/workflows/mech-review.yml@v0.2.2\n    with:\n'; cat; } > "$1/.github/workflows/mech-review.yml"; commit "$1" caller; }
GOOD_WITH='      stack: rust
      project-dir: crates/app
      test-paths: crates/app/tests/**
      extra-apt-packages: libseccomp-dev bubblewrap
      setup-command: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
      rust-toolchain: 1.96.0'
RUST_INPUTS='{"stack":"rust","project-dir":"crates/app","test-paths":"crates/app/tests/**","extra-apt-packages":"libseccomp-dev bubblewrap","setup-command":"sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0","rust-toolchain":"1.96.0"}'
# state of a repo as `git` sees it: HEAD, refs, status, worktrees
snapshot() { git -C "$1" rev-parse HEAD; git -C "$1" for-each-ref; git -C "$1" status --porcelain --ignored; git -C "$1" worktree list; git -C "$1" stash list; }
