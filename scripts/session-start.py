"""SessionStart hook: record tree baseline, inject preflight warnings and the kit's always-on rules."""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

RULES = """[ek] Working rules:
- A test or check goes red → classify it with the failure-triage skill before editing code.
- Before the final report, or when stopping blocked → follow the finish skill.
- Same blocker 3× (missing tool, auth, approval denied, quota) → stop retrying; hand the user a Needs-you block (finish skill).
- A denied or blocked command stays blocked: ask the user, keeping the exact command. Usage limit hit → stop."""


def main():
    raw = sys.stdin.read()
    data = json.loads(raw or "{}")
    cwd = data.get("cwd") or os.getcwd()
    subprocess.run([sys.executable, "-I", os.path.join(HERE, "finish-gate.py"), "--baseline"], input=raw, text=True)
    pf = subprocess.run(["bash", os.path.join(HERE, "preflight.sh"), "--quiet", cwd], capture_output=True, text=True).stdout.strip()
    ctx = RULES + (f"\n[ek] Preflight (this env):\n{pf}" if pf else "")
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": ctx}}))


if __name__ == "__main__":
    main()
