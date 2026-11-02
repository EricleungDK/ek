#!/bin/bash
# Every skill's frontmatter is valid YAML: an unquoted `: ` or ` #` in a value breaks strict parsers, though the plugin loader tolerates it.
source "$(dirname "$0")/lib.sh"
for f in "$ROOT"/skills/*/SKILL.md; do
  name="$(basename "$(dirname "$f")")"
  bad="$(python3 -I - "$f" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
if lines[0] != "---" or "---" not in lines[1:]:
    print("no frontmatter")
    sys.exit()
for n, line in enumerate(lines[1:lines.index("---", 1)], 1):
    m = re.match(r"^[\w-]+:\s*(.*)$", line)
    if not m:
        print(f"line {n}: not key: value")
    elif m.group(1)[:1] not in "\"'" and (": " in m.group(1) or " #" in m.group(1) or m.group(1).endswith(":")):
        print(f"line {n}: unquoted `: ` or ` #`")
PY
)"
  eq "$bad" "" "$name: frontmatter is valid YAML"
done
done_tests
