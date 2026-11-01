#!/bin/bash
# sandbox HOME files: not the work, keep the finish gate quiet
set -e
git init -q .
printf '.gitconfig\n.config/\n.npm/\n' >> "$(git rev-parse --git-dir)/info/exclude"
