#!/bin/bash
# fixture: lsx CLI; v1.0 prints plain names, HEAD adds --json; weak scenario (non-empty output only)
set -e
git init -q -b main .; git config user.email t@t; git config user.name t
cat > lsx.py <<'PY'
import os, sys
print("\n".join(sorted(os.listdir(sys.argv[-1] if len(sys.argv) > 1 and not sys.argv[-1].startswith("-") else "."))))
PY
git add -A; git commit -qm "lsx v1"; git tag v1.0
cat > lsx.py <<'PY'
import json, os, sys
args = [a for a in sys.argv[1:] if not a.startswith("-")]
names = sorted(os.listdir(args[0] if args else "."))
print(json.dumps(names) if "--json" in sys.argv else "\n".join(names))
PY
mkdir -p .ek/scenarios/json-output
cat > .ek/scenarios/json-output/SCENARIO.md <<'MD'
- story: user gets machine-readable listing
- covers: "`lsx --json` prints a valid JSON array"
- steps: run `python3 lsx.py --json` in a dir with files
- expected: JSON array output
MD
cat > .ek/scenarios/json-output/run.sh <<'SH'
touch a b
python3 "$EK_REPO/lsx.py" --json . > out.txt
test -s out.txt
SH
git add -A; git commit -qm "lsx --json + scenario"
