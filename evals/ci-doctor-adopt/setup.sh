#!/bin/bash
# fixture: Alfredo's shape. Crate in a subdir, bwrap + AppArmor sysctl only visible in existing CI, Rust pinned via env.
set -e
git init -q -b main .; git config user.email t@t; git config user.name t
printf '.gitconfig\n.config/\n.npm/\n' >> .git/info/exclude  # sandbox HOME files: not the work, keep the finish gate quiet
mkdir -p app-tui/src app-tui/tests .github/workflows
printf '[package]\nname = "app-tui"\nversion = "0.1.0"\nedition = "2021"\n' > app-tui/Cargo.toml
echo 'pub fn add(a: i32, b: i32) -> i32 { a + b }' > app-tui/src/lib.rs
printf '#[test]\nfn adds() { assert_eq!(app_tui::add(1, 1), 2); }\n' > app-tui/tests/a.rs
cat > .github/workflows/ci.yml <<'Y'
name: ci
on: [push]
env:
  RUSTUP_TOOLCHAIN: 1.96.0
jobs:
  checks:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - run: rustup toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal
      - run: |
          sudo apt-get update
          sudo apt-get install --yes bubblewrap util-linux
          # Ubuntu 24.04 AppArmor blocks unprivileged user namespaces that bwrap needs.
          sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 || true
      - run: cargo test --locked
        working-directory: app-tui
Y
git add -A; git commit -qm base
