---
name: ci-doctor
description: Set up or repair a repo's mech-review CI. Use when adopting mech-review, or when its check reports `no result`, `n/a`, or a CI entry.
---

Ends in a PR a person merges. `.github/**` is a human decision, so your last action is opening that PR.

`DOCTOR` = `python3 -I <kit>/scripts/mech-review.py doctor --repo <repo>`. `<kit>` = the `scripts/` parent named by the `[ek] Scenario runner:` session line. Exit 0 no problems, 1 problems, 2 usage.

## 1. Diagnose

Run `DOCTOR` on the default branch, no hints. Several projects found → ask which, then pass `--stack` and `--project-dir`.

Keep `inputs`, `trial` and each entry's `hint`: the hint is the exact fix.

## 2. Read what doctor can't

Read `.github/workflows/*`. Anything the tests depend on that isn't in `inputs` goes into `setup-command`: env values, services, setup steps.

## 3. Write the caller

On a new branch, write or repair `.github/workflows/mech-review.yml`. Keep inputs already there; add or correct only what entries name.

```yaml
name: mech-review
on:
  pull_request:
permissions:
  contents: read
  pull-requests: write
jobs:
  mech-review:
    uses: EricleungDK/ek/.github/workflows/mech-review.yml@v0
    with:
      # every key in doctor's `inputs`
      protected-paths: |
        .github/**
```

Ask the user for `protected-paths` beyond `.github/**` and for `agent-branch-prefix`; they own both.

## 4. Iterate

Commit (doctor reads HEAD), then rerun `DOCTOR`. Done when it exits 0. An entry that survives its fix twice → stop with a Needs-you block (finish).

`env` entries on this machine may be local-only: a missing tool here says nothing about the runner, and `mutation_tool: absent` gets no entry because CI installs it. Report them as verification debt unless the workflow also lacks the input.

## 5. Open the PR

Push and open the PR. Body: doctor's `summary` at the branch head, the `trial` verdicts, each input and why. Say the PR's own mech-review check goes red `needs-human` by design, and the owner merges.

Report the PR URL via finish. Stopped before the PR (blocked, no remote, asked to) → the final report itself carries the full caller YAML and PR body.
