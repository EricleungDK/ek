# mech-review CI (adopters)

Reusable workflow: `EricleungDK/ek/.github/workflows/mech-review.yml`. On each PR it runs three jobs and merges them into one sticky comment (marker `<!-- mech-review -->`) and one check result:

- `guard`: R2 test-diff guard (`scripts/mech-review.py r2`), git diffs only, no toolchain.
- `red-first`: R1 red-first and R4 determinism (`scripts/mech-review.py red`). Compiles and runs the PR's new or changed tests, so it needs the stack toolchain.
- `report`: merges the two results, edits the comment, sets the check.

Rules: [testing standard](testing-standard.md).

## Caller

Add to your repo, pin an ek release tag (`v0.1.1` is an example; use the tag that ships this workflow):

```yaml
name: mech-review
on:
  pull_request:
permissions:
  contents: read
  pull-requests: write
jobs:
  mech-review:
    uses: EricleungDK/ek/.github/workflows/mech-review.yml@v0.1.1
    with:
      stack: rust
      test-paths: |
        tests/**
      protected-paths: |
        .github/**
```

The ek scripts run at the ref you pin (`job.workflow_sha` of the called file), not at your checkout. Bump the tag to upgrade.

## Inputs

| Input | Default | Use |
|---|---|---|
| `stack` | `rust` | language adapter (only `rust` exists). `rust` sets up the toolchain for `red-first` |
| `test-paths` | `tests/**` | test file globs, one per line; `.rs` files here count every assert; a `.rs` file outside them is production code for R1 |
| `protected-paths` | `.github/**` | globs, one per line; any change under them is a `needs-human` fail |
| `agent-branch-prefix` | `agent/` | R1 runs only when the PR head branch starts with it (`--agent-prefix`); other branches skip R1 |
| `mutation-budget` | `` | **unused**; reserved for R3 (mutants) |
| `extra-apt-packages` | `` | apt packages (space-separated) installed before `red-first` runs its tests |

Globs: `**` any depth, `*` one segment.

## Result

- Jobs: `guard` (artifact `mech-review-json`), `red-first` (artifact `mech-review-red-json`), `report` (`needs` both, runs even if one fails).
- `report` merges the results: each job owns its checks (R2 from `guard`; R1 and R4 from `red-first`). It edits the sticky comment, or creates it: a summary line, a table of entries (id, severity, file:line, problem, forbidden) and the full JSON.
- A job with no usable result (crash, no JSON, or a result for an older head) fails its own checks and adds one `CI` entry naming the job. The other job's entries still show.
- Check fails on any `fail` entry (`confirm` entries do not fail).
- R1 on a non-agent branch, or a PR with no production file changed, is `skipped` and named as such. A missing toolchain is `n/a` (not run, not pass).
- Summary: `all pass <sha>` only when every check ran and passed. A full CI run reads like `pass <sha> (0 fail, 1 confirm; ran: R1 R2 R4; skipped: R3)`. R3 is not built yet, so `all pass` does not appear yet.
- Require the check `mech-review report` in branch protection.
- Readers trust only the bot's marker comment (`github-actions[bot]`, override `MECH_COMMENT_AUTHOR`): a `<!-- mech-review -->` comment from any other user is ignored.
- A run whose PR head has moved on leaves the comment alone; the newest push owns it.

## Limits

- Fork PRs get a read-only `GITHUB_TOKEN`: the comment cannot be posted, so `report` fails. The result is still in the job summary.
- Permissions are `contents: read` and `pull-requests: write` only. The workflow uses `pull_request`, not `pull_request_target`, so forks get no secrets.
- `guard` decides from git diffs only. `red-first` compiles and runs the PR's tests (the code under review) with the workflow token: `pull-requests: write` on same-repo PRs, read-only on forks, and no other secrets.
- R1 needs the branch name: the workflow passes `github.head_ref`. A run without it skips R1 and says so.
- The red commit is checked out as a git worktree; the caller's checkout is not moved.
