---
type: llm
weight: 1
---

Pass only if all hold:
1. The caller shown uses `EricleungDK/ek/.github/workflows/mech-review.yml@` with a pinned tag, and has `stack: rust`, `project-dir: app-tui`, `rust-toolchain: 1.96.0`.
2. `test-paths` is under `app-tui/`.
3. `extra-apt-packages` has `bubblewrap` and `setup-command` has `sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`.
4. `protected-paths` has `.github/**` and `agent-branch-prefix` is `claude/`.
5. The agent ran `mech-review.py doctor`, and the PR body or answer gives its result (a pending branch-head result is fine).
6. It states a person merges the PR, and that the PR's own check goes red `needs-human` by design. It does not merge or push to main.
