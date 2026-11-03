#!/bin/bash
# Claude Code on the web: paste into the environment's setup script.
# Fetches the kit and installs it into every git repo found in the VM.
KIT="$HOME/.ekit"
if [[ -d $KIT/.git ]]; then git -C "$KIT" pull -q --ff-only; else git clone -q --depth 1 https://github.com/EricleungDK/ekit "$KIT"; fi
found=0
for g in $( { git -C "$PWD" rev-parse --show-toplevel 2>/dev/null; find "$HOME" /workspace /workspaces /repo -maxdepth 3 -name .git -type d 2>/dev/null | xargs -r -n1 dirname; } | sort -u); do
  [[ $g == "$KIT" ]] && continue
  bash "$KIT/cloud/install.sh" "$g" && found=1
done
(( found )) || echo "ekit: no repo found yet (pwd=$PWD); run: bash ~/.ekit/cloud/install.sh <repo>"
