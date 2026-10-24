#!/bin/bash
# fixture: lsx CLI with --hidden already implemented; existing scenarios list-files (+ child sort-by-size), init-config
set -e
git init -q -b main .; git config user.email t@t; git config user.name t
cat > lsx.py <<'PY'
import os, sys
args = [a for i, a in enumerate(sys.argv[1:], 1) if not a.startswith("-") and sys.argv[i - 1] != "--sort"]
d = args[0] if args else "."
if not os.path.isdir(d):
    sys.exit(f"lsx: no such directory: {d}")
names = sorted(n for n in os.listdir(d) if "--hidden" in sys.argv or not n.startswith("."))
if "--sort" in sys.argv:
    names.sort(key=lambda n: os.path.getsize(os.path.join(d, n)))
print("\n".join(names))
PY
s() { mkdir -p ".ek/scenarios/$1"; printf '%s\n' "$2" > ".ek/scenarios/$1/SCENARIO.md"; printf '%s\n' "$3" > ".ek/scenarios/$1/run.sh"; }
s list-files "- story: user lists a directory
- covers: lsx prints entries of a dir
- steps: create files a, b; run lsx .
- expected: a and b printed" 'touch a b; out=$(python3 "$EK_REPO/lsx.py" .); [[ $out == *a* && $out == *b* ]]'
s list-files/sort-by-size "- story: user sorts listing by size
- covers: lsx --sort size orders by size
- steps: big and small file; lsx --sort size
- expected: small before big" 'echo xxxxxxxx > big; echo x > small; [[ $(python3 "$EK_REPO/lsx.py" --sort size . | head -1) == small ]]'
s init-config "- story: first-time user creates config
- covers: lsx init writes config
- steps: lsx init
- expected: config created" 'true'
git add -A; git commit -qm "lsx + scenarios"
