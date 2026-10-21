#!/bin/bash
# Install the kit into a repo's .claude/ (for cloud sessions, which load no plugins).
# Copies skills, merges hooks into .claude/settings.json, hides both from git. Idempotent.
# Usage: install.sh [repo-dir]
set -euo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "${1:-$PWD}" && git rev-parse --show-toplevel)"
mkdir -p "$REPO/.claude/skills"
exclude="$(git -C "$REPO" rev-parse --git-path info/exclude)"; [[ $exclude = /* ]] || exclude="$REPO/$exclude"
mkdir -p "$(dirname "$exclude")"; touch "$exclude"
hide() { grep -qxF "$1" "$exclude" || echo "$1" >> "$exclude"; }

for s in "$KIT"/skills/*/; do
  name="$(basename "$s")"
  [[ -e $REPO/.claude/skills/$name ]] && ! grep -qxF "/.claude/skills/$name/" "$exclude" && continue
  rm -rf "$REPO/.claude/skills/$name"; cp -r "$s" "$REPO/.claude/skills/$name"
  hide "/.claude/skills/$name/"
done

settings="$REPO/.claude/settings.json"
tracked=0; git -C "$REPO" ls-files --error-unmatch .claude/settings.json >/dev/null 2>&1 && tracked=1
python3 -I - "$KIT/hooks/hooks.json" "$settings" "$KIT" <<'EOF'
import json, os, sys
src, dst, kit = sys.argv[1:]
kit_hooks = json.loads(open(src).read().replace("${CLAUDE_PLUGIN_ROOT}", kit))["hooks"]
cfg = json.load(open(dst)) if os.path.exists(dst) else {}
hooks = cfg.setdefault("hooks", {})
for event, groups in kit_hooks.items():
    have = hooks.setdefault(event, [])
    for g in groups:
        if g not in have:
            have.append(g)
json.dump(cfg, open(dst, "w"), indent=2)
EOF
if (( tracked )); then git -C "$REPO" update-index --skip-worktree .claude/settings.json
else hide "/.claude/settings.json"; fi
echo "ek installed into $REPO"
