#!/bin/bash
#
# Auto-commit script (macOS).
# Discovers every git repo under $ROOT and commits any local changes.
# Intended to be run on a schedule by launchd (see LaunchAgents/).

# --- Environment (launchd runs with a minimal PATH) ---
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Root under which to search for git repositories (override with AUTOGIT_ROOT).
ROOT="${AUTOGIT_ROOT:-$HOME/Projects}"

# Log file lives OUTSIDE the scanned repos so we never commit our own logs.
LOG_DIR="$HOME/Library/Logs/auto-git"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/commit.log"
exec >>"$LOG_FILE" 2>&1

COMMIT_MESSAGE="Auto Commit: $(date '+%Y-%m-%d %H:%M:%S')"

echo "===================================================="
echo "=== Starting auto-commit at $(date '+%Y-%m-%d %H:%M:%S') ==="
echo "Root: $ROOT"
echo "Commit message: $COMMIT_MESSAGE"
echo "----------------------------------------------------"

# Discover repos: find every .git directory, ignoring common vendored dirs.
find "$ROOT" -type d \( \
      -name node_modules -o -name vendor -o -name Pods -o -name .venv \
      -o -name venv -o -name .tox -o -name DerivedData -o -name .next \
      -o -name build -o -name dist \
    \) -prune -o -type d -name .git -print 2>/dev/null | while IFS= read -r gitdir; do

  repo="$(dirname "$gitdir")"
  cd "$repo" || continue

  git add -A
  if git diff --cached --quiet; then
    echo "🟡 No changes: $repo"
  else
    if git commit -m "$COMMIT_MESSAGE" >/dev/null; then
      echo "✅ Committed: $repo"
    else
      echo "❌ Commit FAILED: $repo"
    fi
  fi
done

echo "🎉 Auto-commit finished at $(date '+%Y-%m-%d %H:%M:%S')"
