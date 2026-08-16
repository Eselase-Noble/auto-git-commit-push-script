#!/bin/bash
#
# Auto-push script (macOS).
# Discovers every git repo under $ROOT and pushes the CURRENT branch to origin.
# Authentication uses the macOS keychain via git's osxkeychain credential helper
# (already configured system-wide), so no SSH key is needed for HTTPS remotes.
# Intended to be run on a schedule by launchd (see LaunchAgents/).

# --- Environment (launchd runs with a minimal PATH) ---
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Root under which to search for git repositories (override with AUTOGIT_ROOT).
ROOT="${AUTOGIT_ROOT:-$HOME/Projects}"

# Log file lives OUTSIDE the scanned repos so we never commit our own logs.
LOG_DIR="$HOME/Library/Logs/auto-git"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/push.log"
exec >>"$LOG_FILE" 2>&1

echo "===================================================="
echo "=== Starting auto-push at $(date '+%Y-%m-%d %H:%M:%S') ==="
echo "Root: $ROOT"
echo "----------------------------------------------------"

find "$ROOT" -type d \( \
      -name node_modules -o -name vendor -o -name Pods -o -name .venv \
      -o -name venv -o -name .tox -o -name DerivedData -o -name .next \
      -o -name build -o -name dist \
    \) -prune -o -type d -name .git -print 2>/dev/null | while IFS= read -r gitdir; do

  repo="$(dirname "$gitdir")"
  cd "$repo" || continue

  # Must have an 'origin' remote.
  if ! git remote get-url origin >/dev/null 2>&1; then
    echo "🟡 No origin remote, skipping: $repo"
    continue
  fi

  # Current branch (skip detached HEAD).
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ -z "$branch" ] || [ "$branch" = "HEAD" ]; then
    echo "🟡 Detached HEAD, skipping: $repo"
    continue
  fi

  # Only push when there is actually something to push.
  if git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
    # Upstream exists: push only if we are ahead.
    ahead="$(git rev-list --count '@{upstream}..HEAD' 2>/dev/null)"
    if [ "${ahead:-0}" -eq 0 ]; then
      echo "🟡 Nothing to push ($branch up to date): $repo"
      continue
    fi
  fi

  if git push origin "$branch" >/dev/null 2>&1; then
    echo "✅ Pushed $branch: $repo"
  else
    echo "❌ Push FAILED ($branch): $repo — check credentials/remote permissions"
  fi
done

echo "🎉 Auto-push finished at $(date '+%Y-%m-%d %H:%M:%S')"
