# mech-review CI (adopters)

Reusable workflow: `EricleungDK/ek/.github/workflows/mech-review.yml`. On each PR it runs the R2 test-diff guard (`scripts/mech-review.py r2`, no toolchain), then edits one sticky comment (marker `<!-- mech-review -->`) and sets the check result. Rules: [testing standard](testing-standard.md).

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
| `stack` | `rust` | language adapter (only `rust` exists) |
| `test-paths` | `tests/**` | test file globs, one per line; `.rs` files here count every assert |
| `protected-paths` | `.github/**` | globs, one per line; any change under them is a `needs-human` fail |
| `agent-branch-prefix` | `agent/` | **unused by the R2 guard**; reserved for R1 (red-first) |
| `mutation-budget` | `` | **unused by the R2 guard**; reserved for R3 (mutants) |
| `extra-apt-packages` | `` | **unused by the R2 guard**; reserved for toolchain jobs (R1/R3) |

Globs: `**` any depth, `*` one segment.

## Result

- Jobs: `guard` (R2, JSON saved as artifact `mech-review-json`) and `report` (runs even if guard fails).
- `report` edits the sticky comment, or creates it: a summary line, a table of entries (id, severity, file:line, problem, forbidden) and the full JSON.
- Check fails on any `fail` entry (`confirm` entries do not fail). Guard error (usage or git, no JSON) fails the check and the comment says no result.
- Summary: `all pass <sha>` only when every check ran. R2 alone reads `pass <sha> (0 fail, 0 confirm; ran: R2; skipped: R1 R3 R4)`.
- Require the check `mech-review report` in branch protection.
- Readers trust only the bot's marker comment (`github-actions[bot]`, override `MECH_COMMENT_AUTHOR`): a `<!-- mech-review -->` comment from any other user is ignored.
- A run whose PR head has moved on leaves the comment alone; the newest push owns it.

## Limits

- Fork PRs get a read-only `GITHUB_TOKEN`: the comment cannot be posted, so `report` fails. The result is still in the job summary.
- Permissions are `contents: read` and `pull-requests: write` only. The workflow uses `pull_request`, not `pull_request_target`, so forks get no secrets.
- The guard decides from git diffs only. It does not run the PR's code.
