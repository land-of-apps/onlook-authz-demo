#!/usr/bin/env bash
# Copies your changes in base/ and head/ back into overlay/, which is what this repo commits.
#
# overlay/<side> is exactly "every file that differs from the upstream commit". So this script
# commits the worktree locally, asks git which files differ from upstream, and copies those.
# bun.lock and editor folders are left out: installs and editors change them, we do not.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

sync_side() {  # sync_side <side> <sha>
  local side="$1" sha="$2" f
  [ -d "$side" ] || { echo "$side/ does not exist, run ./setup.sh first" >&2; exit 1; }
  git -C "$side" add -A -- . ':!bun.lock' ':!.vscode' ':!.idea'
  git -C "$side" diff --cached --quiet || git -C "$side" -c user.name=goldtrace \
    -c user.email=goldtrace@example.invalid commit -q -m "appmap: update on $side"
  rm -rf "overlay/$side" && mkdir -p "overlay/$side"
  git -C "$side" diff --name-only --diff-filter=d "$sha" HEAD -- . ':!bun.lock' | while read -r f; do
    mkdir -p "overlay/$side/$(dirname "$f")"
    cp "$side/$f" "overlay/$side/$f"
  done
  echo "overlay/$side: $(find "overlay/$side" -type f | wc -l | tr -d ' ') files"
}
sync_side base "$BASE_SHA"
sync_side head "$HEAD_SHA"
git status --short overlay | head -20
