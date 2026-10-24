# Drivers

Install the deliverable the way a user does, in the scenario's temp cwd, then drive it.

| Deliverable | Install | Drive | Assert |
|---|---|---|---|
| CLI | `pip install -e .` / `npm i -g .` / `cargo install --path .` | shell: args, stdin, exit code | stdout/stderr, exit code, files written |
| TUI | same | `tmux new -d`, `send-keys`, `capture-pane`; or `expect` | pane text |
| HTTP API | launch server in background, wait for port | `curl`, `jq` | status, body fields; kill server on exit |
| Web UI | launch server | `playwright` script | DOM text, screenshot only as artifact |
| Library | build/pack, install the artifact into a fresh venv/project | consumer script importing it | script output, exit code |
| Batch job | run entrypoint on fixture input | shell | output files, row counts, rerun idempotence |
| Claude plugin | `claude plugin marketplace add <repo>`, `claude plugin install` | `claude -p "<prompt>"` | output text, hook JSON, files |

Misuse cases per row: no args, bad flag, malformed input, missing config (first use), port in use, empty input.
Missing tool: preflight warns; report the scenario unrunnable.
