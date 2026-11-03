#!/bin/bash
# move-major-tag.sh TAG [REMOTE]: point the floating major tag (v0 for v0.2.5) at release TAG's
# commit and push it to REMOTE (default origin). Callers pin `mech-review.yml@v0`, so a release
# reaches them without a bump in their repo.
#
# Forward only: when the remote's major tag points at a commit TAG does not contain, nothing
# moves (exit 3), so re-tagging an old patch never rolls callers back. The remote's tag is
# the truth; a stale local copy is ignored.
# Exit: 0 moved or already there, 2 usage (TAG is not vX.Y.Z), 3 refused (would move back).
set -euo pipefail

tag="${1:-}"
remote="${2:-origin}"
if [[ ! $tag =~ ^v([0-9]+)\.[0-9]+\.[0-9]+$ ]]; then
  echo "move-major-tag: want a release tag vMAJOR.MINOR.PATCH, got '${tag}'" >&2
  exit 2
fi
major="v${BASH_REMATCH[1]}"
sha="$(git rev-parse "${tag}^{commit}")"

cur="$(git ls-remote "$remote" "refs/tags/${major}^{}" | cut -f1)"
[[ -n $cur ]] || cur="$(git ls-remote "$remote" "refs/tags/${major}" | cut -f1)"
if [[ -n $cur ]]; then
  if [[ $cur == "$sha" ]]; then
    echo "${major} already at ${tag} (${sha})"
    exit 0
  fi
  git fetch -q "$remote" "$cur" 2>/dev/null || true
  if ! git merge-base --is-ancestor "$cur" "$sha" 2>/dev/null; then
    echo "move-major-tag: ${major} is at ${cur}, which ${tag} does not contain: not moved back" >&2
    exit 3
  fi
fi

git tag -f "$major" "$sha" >/dev/null
git push -q -f "$remote" "refs/tags/${major}"
echo "${major} -> ${tag} (${sha})"
