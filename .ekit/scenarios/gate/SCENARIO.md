# gate: Stop hook allows only on fresh PASS

- story: As a user with the kit installed, in a session started with /orchestrate-agent, Claude cannot stop on unverified work in a repo with scenarios, and can once scenarios are green.
- covers: #9 scenario per deliverable (Stop gate); the gate allows the stop after a fresh PASS
- steps:
  1. Sample repo with passing scenario `ok`; cloud/install.sh; fire the installed SessionStart hook (records baseline).
  2. Edit without /orchestrate-agent -> Stop allows (gate is orchestrate-only); revert; fire the installed UserPromptSubmit hook with `/orchestrate-agent` (arms the gate).
  2b. Stop hook, no work done -> allow (no output).
  3. Edit a file; Stop hook -> block ("Scenarios not green"), naming the runner.
  4. Run the runner -> PASS; Stop hook -> allow (no output).
  5. stop_hook_active=true -> allow (loop guard).
- expected: block JSON `{"decision":"block"...}` only in step 3.
- children: stale-after-edit, failing-scenario
