# Subagent brief template

Fill every section. The agent sees nothing but this brief.

```
Repo: <absolute path>, branch `<branch>` (HEAD <sha>, pushed: yes/no; PR #<n> if any).
Spec: <issue link, or "free-form task"> — checklist items this unit owns: <items>.
Unit: <name>; files you own: <paths>; do not edit: <other units' files>; depends on: <unit / interface or none>.
Read first: <AGENTS.md, repo docs index, the specific docs/reports for this area>.
Owner rules: <commit style, attribution trailer text, docs to update>. Testing standard: <link from the repo's testing doc>.

Work: <outcome to build (behaviour, interface, acceptance) / the exact failure: assertion, CI run and job id, command that shows it / or the failing mech-review entries verbatim: id, file, line, problem, hint, forbidden>.
Scenarios: <ids this unit must keep green, or none; failing scenario id + transcript as repro on fix rounds>.
Known context: <recent commits that may be involved, suspects, what was ruled out>.
Environment: <how to run tests here: env vars, binaries, build step first>.

Tasks:
1. Build: `test(red)` commit first (failing test for the outcome), then the implementation, one slice at a time.
   Fix: reproduce and capture the actual error; classify it with the failure-triage skill; check new vs pre-existing on the parent commit in a temp worktree (remove it after); fix the root cause red first (test-only fix only when the test is wrong).
2. Stay in your files; a needed change elsewhere goes in your report, not your diff.
3. Keep guards and checks at full strength. Forbidden: delete, skip or weaken a test; change an expected value to match output; suppress a lint without reason; edit protected paths; pass a test before the fix. Full table: testing standard §3. No waivers.
4. Verify: <exact commands, and how many runs>.
5. Docs: <task log entry, report section, SOP rule if reusable>.
6. Commit on <branch>. A fix for a mech entry carries body line `mech: <id>` (rounds count per id). Commit message ends with:
   <attribution trailer>
7. Review: you cannot spawn agents, so the orchestrator runs R2, then your review. Stop and report a REVIEW REQUEST: branch, base SHA, head SHA, checklist items covered, files changed, focus areas. Wait; findings arrive by message. Fix the real ones red-first, re-verify, then finish or request review again.
8. Push: <yes after review passes, then watch `gh pr checks <n> --watch` / no>.
9. Fix rounds (each review-fix cycle counts; per entry `id` too): up to <rounds left of 3>; after that, stop and report.

Do not merge. Any other step in your flow that spawns agents: hand it to the orchestrator the same way as review.
Report with the finish skill (done or blocked branch), plus: what was built or the error, cause and new vs pre-existing (fixes), commits.
```
