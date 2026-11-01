# mech-review CI (adopters)

Reusable workflow: `EricleungDK/ek/.github/workflows/mech-review.yml`. On each PR it runs up to five jobs and merges them into one sticky comment (marker `<!-- mech-review -->`) and one check result:

- `guard`: R2 test-diff guard (`scripts/mech-review.py r2`), git diffs only, no toolchain.
- `red-first`: R1 red-first and R4 determinism (`scripts/mech-review.py red`). Compiles and runs the PR's new or changed tests, so it needs the stack toolchain (rust: stable; python: a venv with pytest; ts: node 22 and the repo's installed dependencies).
- `plan`: decides whether R3 runs (a production file changed) and its shard matrix (4 shards). Git only.
- `mutants`: R3 mutation on the diff (`scripts/mech-review.py mutants`), one job per shard. Runs cargo-mutants 27.1.0 (`--in-diff`) on the PR's code (rust), mutmut 3.8.1 on the changed files (python), or Stryker 10.0.0 on the changed lines (ts). Skipped entirely when `plan` says no production file changed.
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

Python: the same, with `stack: python` and `test-paths: tests/**` (`tests/test_*.py` or any layout under `tests/`).

TypeScript / JavaScript: `stack: ts` with `test-paths: src/**/*.test.ts` (or `tests/**`). `.ts .tsx .js .jsx .mjs .cjs` files are this stack; the project dir needs a `package.json`.

The ek scripts run at the ref you pin (`job.workflow_sha` of the called file), not at your checkout. Bump the tag to upgrade.

## Inputs

| Input | Default | Use |
|---|---|---|
| `stack` | `rust` | language adapter: `rust` (cargo test, cargo-mutants), `python` (pytest, mutmut) or `ts` (vitest or jest, Stryker). Sets up the toolchain for `red-first` and `mutants` |
| `test-paths` | `tests/**` | test file globs, one per line; `.rs` files here count every assert; a `.rs` file outside them is production code for R1 |
| `protected-paths` | `.github/**` | globs, one per line; any change under them is a `needs-human` fail |
| `agent-branch-prefix` | `agent/` | R1 runs only when the PR head branch starts with it (`--agent-prefix`); other branches skip R1 |
| `mutation-budget` | `10` | R3 budget in minutes, per mutants shard. A budget hit is `partial` (no MISSED so far) or `fail` (a MISSED found), never a crash. Applies to both stacks |
| `extra-apt-packages` | `` | apt packages (space-separated) installed before `red-first` runs its tests |
| `project-dir` | `.` | crate dir under the repo root (`package.json` for ts). R1, R4 and R3 run there; `test-paths` and `protected-paths` stay repo-root globs; a path with `..` or a leading `/` is a usage error |
| `setup-command` | `` | shell command (run with bash) in `red-first` and `mutants`, after `extra-apt-packages`, before the tests. A non-zero exit stops that job, which then reports a CI entry |

Globs: `**` any depth, `*` one segment.

Subdirectory crate (`project-dir`): `test-paths: alfredo-tui/tests/**`, `project-dir: alfredo-tui`. Tests and cargo-mutants run in that dir; results name files from the repo root (`alfredo-tui/src/x.rs`).

`setup-command` is for host setup a test needs and `extra-apt-packages` cannot do, e.g. an AppArmor sysctl for bubblewrap:

```yaml
    with:
      setup-command: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 || true
```

Trust: `setup-command` and `project-dir` come from the caller's workflow file, which is trusted: the command runs with the job's `contents: read` token and no secrets. For `pull_request` the caller file is the PR's own, so a PR that edits it changes what the job runs. Keep that file behind review: `.github/**` in `protected-paths` reports such an edit as `needs-human`, but the job runs before a human reads it. Both inputs are passed through `env` and never interpolated into a `run:` line. The command runs at the workspace root, before the PR's tests.

Python toolchain (`stack: python`), set up in `red-first` and `mutants`:

- A venv from the runner's python (`$RUNNER_TEMP/py-venv`), so PEP 668 does not apply. `pytest` 9.2.0, and in `mutants` `mutmut` 3.8.1. Both pinned.
- The `requirements*.txt` files in the project dir (`project-dir`, default the repo root) are installed with `pip -r`. A requirements file that does not install stops the job: a missing dependency is never a silent pass. `project-dir` must stay under the repo root.
- Installing the project is left to `setup-command`, which runs after this step with the venv on PATH, e.g. `setup-command: python3 -m pip install -e caller` (the checkout is `caller/` under the workspace root; with `project-dir: pkg`, `caller/pkg`).
- An editable install imports the checkout's copy. A flat layout is safe: the runner starts in the worktree, so its package comes first on `sys.path`. A `src/` layout is not: at the red commit R1 would import head's code. Use pytest's `pythonpath` setting for a `src/` layout instead, and skip `setup-command` for it.
- Test runner: `python3 -m pytest` (one nodeid per test, so unittest `TestCase` methods run too). Use `--test-cmd` for another command: a command with `unittest` in it gets dotted names.
- A python project dir needs one of `pyproject.toml`, `setup.py` or `setup.cfg`. Without one R3 is `n/a` and names `project-dir`, and a test that cannot run names it in its hint. `pytest` missing is `n/a (env)`, and its note names `setup-command`.

## Result

- Jobs: `guard` (artifact `mech-review-json`), `red-first` (artifact `mech-review-red-json`), `plan`, `mutants` (artifacts `mech-review-mutants-<shard>`), `report` (`needs` all four, runs even if one fails).
- `report` merges the results: each job owns its checks (R2 from `guard`; R1 and R4 from `red-first`; R3 from `mutants`). The shard results are combined by `mech-review.py merge` first. It edits the sticky comment, or creates it: a summary line, a table of entries (id, severity, file:line, problem, forbidden) and the full JSON.
- A job with no usable result (crash, no JSON, or a result for an older head) fails its own checks and adds one `CI` entry naming the job. The other job's entries still show.
- Check fails on any `fail` entry (`confirm` entries do not fail).
- A `fail` entry of class `needs-human` reads `needs-human` in the comment (severity cell, and the headline when every fail entry is needs-human). The JSON keeps `severity: fail` and the summary keeps `fail`; the check stays red.
- R1 on a non-agent branch, or a PR with no production file changed, is `skipped` and named as such. A missing toolchain is `n/a` (not run, not pass). Each `n/a` note names the cause and the input to set (`setup-command` for a toolchain, the install step for cargo-mutants, `project-dir` for no manifest: `Cargo.toml` for rust, `pyproject.toml`, `setup.py` or `setup.cfg` for python), and the comment adds one line under the headline: `Did not run: R3 (no Cargo.toml in .: set project-dir)`. A missing manifest where R1 or R4 runs is a `fail` (cannot run), with `set project-dir` in its hint.
- Summary: `all pass <sha>` only when every check ran and passed. A run with R3 skipped (no production file changed) reads like `pass <sha> (0 fail, 1 confirm; ran: R1 R2 R4; skipped: R3)`. A budget hit reads `partial: R3 (tested/total)`, and an absent tool reads `n/a: R3`; neither is `all pass`.
- Require the check `mech-review report` in branch protection.
- Readers trust only the bot's marker comment (`github-actions[bot]`, override `MECH_COMMENT_AUTHOR`): a `<!-- mech-review -->` comment from any other user is ignored.
- A run whose PR head has moved on leaves the comment alone; the newest push owns it.

TypeScript toolchain (`stack: ts`), set up in `red-first` and `mutants`:

- `actions/setup-node` (pinned to a full SHA, node 22). The install in `caller/<project-dir>` follows the lockfile: `npm ci` for `package-lock.json`, the repo's `pnpm` (10.34.6) or `yarn` (1.22.22, classic) for theirs, both pinned through `npx`. No lockfile is a stop: the install must be reproducible. Install scripts run, as the test code does; the job's token is read-only.
- The tests run the repo's own runner from its `node_modules/.bin`: `vitest` or `jest`, chosen from `package.json` (vitest when it lists vitest, or neither). A worktree has no `node_modules`, so the engine links the caller checkout's `node_modules` into the worktree's crate dir (never over an existing one; the caller's copy is not touched). A runner that is not installed is `n/a (env)`, named by its `node_modules/.bin` path.
- Named tests: `vitest run <file> -t '^Describe > test$'`, `jest <file> -t '^Describe test$'` (jest joins names with a space). A test name is matched anchored, so `describe("A") > works` and `describe("B") > works` are two tests. `it.each` placeholders match any value.
- Outcomes: a filter that runs nothing is `none` (never a pass, also at exit 0). A file that does not load (transform, missing import, syntax) is `build`: the R1 compile-red confirm, or an R4 fail.
- The test command: `--test-cmd` overrides it (a vitest command gets `run` inserted; a command with `jest` in it gets jest's argv).
- Stryker is installed into the runner temp dir (`@stryker-mutator/core@10.0.0`, `@stryker-mutator/jest-runner@10.0.0`), not the repo's `node_modules`. A failed install is not a stop: R3 is `n/a (env)`.
- Test files are `.ts`/`.js` files matched by `test-paths`; a test is `it`/`test` (and `.each`, `.skip`, `.only`, `.todo`, `xit`, `fit`, `xtest`, `ftest`) inside `describe` or at top level.

## Python R3 (mutmut)

- The runner appends a `[tool.mutmut]` table (`source_paths`, `only_mutate` = the changed production files of the shard) to the worktree's `pyproject.toml`. The caller's checkout is never written. A `setup.cfg` `[mutmut]` section is ignored once the table exists.
- mutmut has no line filter: it mutates every line of the changed files. The runner keeps only the MISSED mutants on changed lines (the line is found in the head source by the mutated function's name, `mutmut show`), the same promise as `--in-diff`. Mutants outside the diff are not reported; the note counts them (`N missed outside the diff`). A method is located inside its class (mutmut names it `Class` + U+01C1 + `method`), so a method name that two classes share is found in the right one. A missed mutant whose name maps to no line in the file is `unlocated`: one `confirm` entry, not a fail and not a silent pass, counted in the note (`N unlocated`) for a reader to check by hand.
- `no tests` (no test reaches the line) is a MISSED mutant: the fix is a test that calls it. Survived mutants are MISSED. `timeout`, `suspicious` and similar are neither caught nor missed, as TIMEOUT and UNVIABLE are for cargo-mutants.
- Timing is wall time only (`checks.R3.timing.wall_s`): mutmut prints no per-phase durations, so the cargo-mutants phase fields are left out, not guessed. `--mutant-timeout` does not apply: mutmut's own timeout (its `timeout_multiplier` times the test time) decides.
- A budget hit reads the results mutmut kept: `partial (tested/total)` with nothing missed, `fail` with a MISSED.

## R3 timing and partial

`checks.R3.timing` (JSON, additive) says where the R3 time went. Per shard it comes from cargo-mutants' own `outcomes.json` phase durations (`Build`, `Test`, in seconds) and the runner's clock:

- `wall_s`: wall time of the cargo-mutants run on this shard.
- `baseline_build_s`, `baseline_test_s`: the unmutated baseline (every shard runs it again).
- `mutant_build_s`, `mutant_test_s`: summed over the tested mutants. A mutant that fails to build has no `Test` phase and adds 0 to it.
- `avg_s_per_mutant`: (`mutant_build_s` + `mutant_test_s`) / tested.
- `slowest`: the five slowest tested mutants, `{name, s}` (`s` = its build plus test seconds).

Merged (`merge`): `wall_s` is the slowest shard, since shards run in parallel. Sums and the average are kept only when every shard reported them. `shards` lists each shard's `wall_s`, so an uneven shard shows. `slowest` is the top five across shards. A field that is missing or not a number is left out, never guessed. A budget-killed run reports what finished.

The comment prints one line under the headline when R3 ran, e.g. `R3 timing: 6/15 mutants, 3.07s wall, avg 0.25s per mutant (build 1.21s, test 0.3s)`. When R3 is partial it adds `R3 slowest:` with the five slowest. Mutant names come from the PR's code, so they pass through the comment's cell rules (pipes escaped, backticks replaced).

A partial R3 adds one `confirm` entry: class `agent-fixable`, id `R3-…` (stable across heads and counts), problem `R3 partial: <untested>/<total> mutants untested at budget` (or `total unknown` when the mutant list was never written). One entry per run, however many shards hit the budget. The check stays green and the exit code stays 0: partial never fails.

What to do with the numbers, in this order:

1. Smaller diff. `untested × avg_s_per_mutant` estimates the extra seconds the shard needs. If that is far above the budget, the diff covers too much for one run: split the change.
2. Narrower tests. If a few mutants dominate `slowest`, their tests are slow for each mutant. Make those tests faster or narrower; the slow test runs once per mutant.
3. Raise `mutation-budget` last. If `baseline_build_s` and `baseline_test_s` are large against `wall_s`, the fixed per-shard cost is the problem: a bigger budget only buys more mutants.

## TypeScript R3 (Stryker)

- Stryker 10.0.0 runs on the changed lines only: each changed run of lines is a `--mutate file:start-end` range. Stryker mutates the mutants fully inside a range, so the MISSED list is already the diff; a mutant outside it is counted in the note, not a fail. Class methods are mutated like any other lines.
- vitest, with no repo Stryker config: a temp `stryker.conf.json` is written into the worktree (the caller's checkout is never written) that runs `npx --no-install vitest run` per mutant with `coverageAnalysis: off`. Stryker's own vitest plugin (`@stryker-mutator/vitest-runner` 10.0.0) completes no test for a test nested in `describe` on vitest 5.0.5 (checked: the mutants read as survived with 0 tests run); vitest 4.1.12 with the same Stryker kills them. The command runner is correct on vitest 5, at the cost of running the whole suite per mutant.
- jest, with no repo config: `--testRunner jest` (the jest plugin, per-test coverage; checked on nested describes).
- A repo with its own Stryker config (`stryker.conf.*`, `stryker.config.*`) keeps it: Stryker reads it, and `mutate`, the reporter and the timeout are set on the command line, which wins over the file. The test runner comes from the repo's config. The JSON report is read from Stryker's default `reports/mutation/mutation.json`; a repo that moves `jsonReporter.fileName` gets `n/a (env)`.
- A covered mutant with no test completed (`coveredBy` set, `testsCompleted` 0, `Survived`) means the runner did not run the tests: R3 is `n/a (env)` for the whole check, not a MISSED. This is the guard for the vitest-plugin case above.
- Results: `Killed` is caught; `Survived` and `NoCoverage` (no test reaches the mutant) are MISSED; `Timeout`, `CompileError`, `RuntimeError`, `Ignored` and `Pending` are neither. A report that is missing or unreadable is `n/a (env)`.
- Budget: Stryker writes its report at the end of a run, so a budget hit before that is `partial` with the mutant count from its log (`tested` unknown). A partial is not blocking.
- Timing is wall time only (`checks.R3.timing.wall_s`): Stryker's JSON has no per-phase durations.
- `--mutant-timeout` sets Stryker's `timeoutMS`.

## Limits

- Fork PRs get a read-only `GITHUB_TOKEN`: the comment cannot be posted, so `report` fails. The result is still in the job summary.
- Permissions are `contents: read` and `pull-requests: write` only. The workflow uses `pull_request`, not `pull_request_target`, so forks get no secrets.
- `guard` decides from git diffs only. `red-first` compiles and runs the PR's tests (the code under review) with a job-level `contents: read` token and no other secrets.
- R1 needs the branch name: the workflow passes `github.head_ref`. A run without it skips R1 and says so.
- `mutants` runs cargo-mutants, which builds and runs the PR's tests once per mutant, with a job-level `contents: read` token and no other secrets. Each shard also runs the unmutated baseline tests, so the cost is per shard.
- cargo-mutants is pinned to 27.1.0 through `taiki-e/install-action` (pinned to a full SHA). If the install fails the step continues and R3 reports `n/a (env)`: a missing tool is never a pass and never a code failure.
- ts: Stryker 10.0.0 is pinned in the workflow. The vitest and jest plugins, and the install scripts of the repo's dependencies, run PR code with a read-only token, as the tests do. Yarn berry (PnP, no `node_modules`) and `node --test` are not supported: the runner is `node_modules/.bin/vitest` or `jest`.
- python: `mutmut` 3.8.1 is pinned in the venv. A repo that already has `[tool.mutmut]` in its `pyproject.toml` gets R3 `n/a (env)`: the runner needs `only_mutate` to limit the run to the changed files, and does not override the repo's table.
- The shard count (4) is fixed in the `plan` job, not an input. The per-mutant timeout is 120 s (`--mutant-timeout`); the budget is per shard, so the wall time of R3 is about the budget, not the budget times the shards.
- R3 runs cargo-mutants in a worktree at the head, in the crate dir (`project-dir`), on `base...head` changes only (`--in-diff`; the diff is made relative to the crate dir, and result paths are mapped back to the repo root). A checkout that does not match head is not mutated.
- The red commit is checked out as a git worktree; the caller's checkout is not moved.

## Trust limits

- R1 and R4 results come from `red-first`, the job that compiles and runs PR code. A malicious test can forge that job's JSON. `red-first` has a read-only token (`contents: read`) and cannot edit the comment, but its result is only as trustworthy as the code it ran. R2 runs in `guard`, a separate job with no PR code, and is the hard guard.
- A red commit that touches non-`.rs` files (for example `Cargo.toml`) is not counted as production, so R1 does not flag it.
- R3 results come from `mutants`, which runs the PR's tests. A malicious test can forge that job's JSON, as with R1 and R4; the read-only token stops it editing the comment, not forging its own result. R2 is still the hard guard for weakened tests.
- R3 measures test strength on the changed production code only. A MISSED mutant can be an equivalent mutant (no observable change): the fix is then to assert the behaviour the code really has, and a reviewer may decide the mutant is not worth a test. There is no waiver: a MISSED mutant stays `fail` until a test kills it or the code changes.
- `partial` (budget hit, nothing MISSED so far) does not block, so part of the diff was not mutated. The reviewer reads the `tested/total` note; a bigger `mutation-budget` (or fewer changed lines) is the fix. A budget hit with a MISSED found is `fail`.
- Shard results are merged by `mech-review.py merge`. A missing or stale shard is a CI `fail` entry that names the shard; the other shards' entries are kept.

