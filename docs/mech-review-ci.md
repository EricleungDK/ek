# mech-review CI (adopters)

Reusable workflow: `EricleungDK/ek/.github/workflows/mech-review.yml`. On each PR it runs up to five jobs and merges them into one sticky comment (marker `<!-- mech-review -->`) and one check result:

- `guard`: R2 test-diff guard (`scripts/mech-review.py r2`), git diffs only, no toolchain.
- `red-first`: R1 red-first and R4 determinism (`scripts/mech-review.py red`). Compiles and runs the PR's new or changed tests, so it needs the stack toolchain.
- `plan`: decides whether R3 runs (a production file changed) and its shard matrix (4 shards). Git only.
- `mutants`: R3 mutation on the diff (`scripts/mech-review.py mutants`), one job per shard. Runs cargo-mutants 27.1.0 (`--in-diff`) on the PR's code, so it needs the stack toolchain. Skipped entirely when `plan` says no production file changed.
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
| `mutation-budget` | `10` | R3 budget in minutes, per mutants shard. A budget hit is `partial` (no MISSED so far) or `fail` (a MISSED found), never a crash |
| `extra-apt-packages` | `` | apt packages (space-separated) installed before `red-first` runs its tests |

Globs: `**` any depth, `*` one segment.

## Result

- Jobs: `guard` (artifact `mech-review-json`), `red-first` (artifact `mech-review-red-json`), `plan`, `mutants` (artifacts `mech-review-mutants-<shard>`), `report` (`needs` all four, runs even if one fails).
- `report` merges the results: each job owns its checks (R2 from `guard`; R1 and R4 from `red-first`; R3 from `mutants`). The shard results are combined by `mech-review.py merge` first. It edits the sticky comment, or creates it: a summary line, a table of entries (id, severity, file:line, problem, forbidden) and the full JSON.
- A job with no usable result (crash, no JSON, or a result for an older head) fails its own checks and adds one `CI` entry naming the job. The other job's entries still show.
- Check fails on any `fail` entry (`confirm` entries do not fail).
- A `fail` entry of class `needs-human` reads `needs-human` in the comment (severity cell, and the headline when every fail entry is needs-human). The JSON keeps `severity: fail` and the summary keeps `fail`; the check stays red.
- R1 on a non-agent branch, or a PR with no production file changed, is `skipped` and named as such. A missing toolchain is `n/a` (not run, not pass).
- Summary: `all pass <sha>` only when every check ran and passed. A run with R3 skipped (no production file changed) reads like `pass <sha> (0 fail, 1 confirm; ran: R1 R2 R4; skipped: R3)`. A budget hit reads `partial: R3 (tested/total)`, and an absent tool reads `n/a: R3`; neither is `all pass`.
- Require the check `mech-review report` in branch protection.
- Readers trust only the bot's marker comment (`github-actions[bot]`, override `MECH_COMMENT_AUTHOR`): a `<!-- mech-review -->` comment from any other user is ignored.
- A run whose PR head has moved on leaves the comment alone; the newest push owns it.

## Limits

- Fork PRs get a read-only `GITHUB_TOKEN`: the comment cannot be posted, so `report` fails. The result is still in the job summary.
- Permissions are `contents: read` and `pull-requests: write` only. The workflow uses `pull_request`, not `pull_request_target`, so forks get no secrets.
- `guard` decides from git diffs only. `red-first` compiles and runs the PR's tests (the code under review) with a job-level `contents: read` token and no other secrets.
- R1 needs the branch name: the workflow passes `github.head_ref`. A run without it skips R1 and says so.
- `mutants` runs cargo-mutants, which builds and runs the PR's tests once per mutant, with a job-level `contents: read` token and no other secrets. Each shard also runs the unmutated baseline tests, so the cost is per shard.
- cargo-mutants is pinned to 27.1.0 through `taiki-e/install-action` (pinned to a full SHA). If the install fails the step continues and R3 reports `n/a (env)`: a missing tool is never a pass and never a code failure.
- The shard count (4) is fixed in the `plan` job, not an input. The per-mutant timeout is 120 s (`--mutant-timeout`); the budget is per shard, so the wall time of R3 is about the budget, not the budget times the shards.
- R3 runs cargo-mutants in a worktree at the head, on `base...head` changes only (`--in-diff`). A checkout that does not match head is not mutated.
- The red commit is checked out as a git worktree; the caller's checkout is not moved.

## Trust limits

- R1 and R4 results come from `red-first`, the job that compiles and runs PR code. A malicious test can forge that job's JSON. `red-first` has a read-only token (`contents: read`) and cannot edit the comment, but its result is only as trustworthy as the code it ran. R2 runs in `guard`, a separate job with no PR code, and is the hard guard.
- A red commit that touches non-`.rs` files (for example `Cargo.toml`) is not counted as production, so R1 does not flag it.
- R3 results come from `mutants`, which runs the PR's tests. A malicious test can forge that job's JSON, as with R1 and R4; the read-only token stops it editing the comment, not forging its own result. R2 is still the hard guard for weakened tests.
- R3 measures test strength on the changed production code only. A MISSED mutant can be an equivalent mutant (no observable change): the fix is then to assert the behaviour the code really has, and a reviewer may decide the mutant is not worth a test. There is no waiver: a MISSED mutant stays `fail` until a test kills it or the code changes.
- `partial` (budget hit, nothing MISSED so far) does not block, so part of the diff was not mutated. The reviewer reads the `tested/total` note; a bigger `mutation-budget` (or fewer changed lines) is the fix. A budget hit with a MISSED found is `fail`.
- Shard results are merged by `mech-review.py merge`. A missing or stale shard is a CI `fail` entry that names the shard; the other shards' entries are kept.

