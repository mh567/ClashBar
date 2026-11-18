#!/usr/bin/env bash
#
# Sync the local `main` with the upstream repository.
#
# Model: `main` = upstream + a small set of backportable fixes. Keeping the
# local delta small is what makes rebasing onto upstream cheap; anything that
# would conflict with upstream belongs on a `fork/*` branch instead.
#
# Usage:
#   Scripts/sync_upstream.sh            # fetch + rebase main onto upstream/main
#   Scripts/sync_upstream.sh --check    # report divergence only, change nothing
#
# Environment:
#   UPSTREAM_REMOTE  remote name for upstream (default: upstream)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
MODE="${1:-sync}"
cd "$ROOT"

if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
  echo "Upstream remote '$UPSTREAM_REMOTE' is not configured." >&2
  echo "Run: git remote add $UPSTREAM_REMOTE https://github.com/Sitoi/ClashBar.git" >&2
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Working tree has uncommitted changes; commit or stash them first." >&2
  exit 1
fi

current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$current_branch" != "main" ]; then
  echo "Refusing to sync from branch '$current_branch'. Switch to main first." >&2
  exit 1
fi

git fetch "$UPSTREAM_REMOTE" --tags

ahead="$(git rev-list --count "${UPSTREAM_REMOTE}/main..main")"
behind="$(git rev-list --count "main..${UPSTREAM_REMOTE}/main")"

echo "Local main: ${ahead} commit(s) ahead, ${behind} behind ${UPSTREAM_REMOTE}/main."

if [ "$behind" -eq 0 ]; then
  echo "Already up to date with ${UPSTREAM_REMOTE}/main."
  exit 0
fi

if [ "$MODE" = "--check" ]; then
  echo "Divergence detected. Run without --check to rebase onto ${UPSTREAM_REMOTE}/main."
  exit 0
fi

# README.md on main is fork-owned: it explains the fork and links to this
# repository's releases. Keep the local copy when it collides with an upstream
# README change; every other conflict still stops the sync for manual handling.
rebase_keeping_readme() {
  local readme_snapshot conflicts
  readme_snapshot="$(mktemp -t clashbar-main-readme.XXXXXX)"
  git show HEAD:README.md >"$readme_snapshot"

  if git rebase "${UPSTREAM_REMOTE}/main"; then
    rm -f "$readme_snapshot"
    return 0
  fi

  while [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; do
    conflicts="$(git diff --name-only --diff-filter=U)"
    if [ "$conflicts" != "README.md" ]; then
      rm -f "$readme_snapshot"
      if [ -z "$conflicts" ]; then
        echo "Rebase stopped without file conflicts; resolve manually." >&2
      else
        echo "Conflicts outside README.md:" >&2
        echo "$conflicts" >&2
        echo "Resolve them, then run: git rebase --continue" >&2
      fi
      return 1
    fi

    echo "Keeping the local README.md."
    cp "$readme_snapshot" README.md
    git add README.md
    GIT_EDITOR=true git rebase --continue || true
  done

  rm -f "$readme_snapshot"
  return 0
}

if [ "$ahead" -eq 0 ]; then
  # Fast-forward is preferable here: main holds no local commits.
  git merge --ff-only "${UPSTREAM_REMOTE}/main"
else
  # Local fixes are replayed on top of upstream, keeping history linear and the
  # delta easy to review or drop once upstream ships equivalent fixes.
  echo "Rebasing ${ahead} local commit(s) onto ${UPSTREAM_REMOTE}/main."
  rebase_keeping_readme
fi

echo "Sync complete. Review, then push with: git push --force-with-lease origin main"
