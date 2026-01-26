#!/bin/bash

# === Environment setup for cron ===
export HOME=/home/nobleson
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Load user shell environment (if it exists)
[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc"
[ -f "$HOME/.profile" ] && source "$HOME/.profile"

# --- Option 1: Use SSH agent if available ---
if [ -z "$SSH_AUTH_SOCK" ]; then
    # Try to attach to an existing ssh-agent socket
    export SSH_AUTH_SOCK=$(ls /tmp/ssh-*/agent.* 2>/dev/null | head -n 1)
fi

# --- Option 2: Use a specific SSH key (works even without agent) ---
export GIT_SSH_COMMAND="ssh -i /home/nobleson/.ssh/id_rsa_auto -o IdentitiesOnly=yes"

# === Directories to search for git repositories ===
SEARCH_DIRS=(
  "/home/nobleson/GLNS/PROJECTS"
  "/home/nobleson/Projects/STARTUPS/Mobile Apps/React-Native/nearfix-mobile"
  "/home/nobleson/Projects/PERSONAL"
  "/home/nobleson/Projects/PERSONAL/AI"
   "/home/nobleson/Nobleson"
  "/home/nobleson/SENDIT-GH"
  "/home/nobleson/Projects/STARTUPS/AfrikodeLab"
  "/home/nobleson/Scripts"

)

echo "=== Starting Auto Push Script ==="
echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
echo "----------------------------------------------------"

# === Main Loop ===
for BASE_DIR in "${SEARCH_DIRS[@]}"; do
  echo "Searching in: $BASE_DIR"
  echo "----------------------------------------------------"

  # Loop through subdirectories
  for dir in "$BASE_DIR"/*; do
    if [ -d "$dir/.git" ]; then
      echo "→ Processing Git repository in: $dir"
      cd "$dir" || continue

      # Check that a valid GitHub remote exists
      if git remote -v | grep -q 'git@github.com'; then
        # Determine current branch (e.g., main or production)
        CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

        # Push to the detected branch (default: production if exists)
        TARGET_BRANCH="production"
        if ! git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
          TARGET_BRANCH="$CURRENT_BRANCH"
          echo "Current Branch: ($CURRENT_BRANCH)"
        fi

        git push origin "$TARGET_BRANCH"
        if [ $? -eq 0 ]; then
          echo "✅ Changes pushed to GitHub ($TARGET_BRANCH) for $dir"
        else
          echo "❌ FAILED to push changes to GitHub ($TARGET_BRANCH) for $dir"
          echo "   → Check SSH key and remote permissions"
        fi
      else
        echo "🟡 No valid GitHub remote found in $dir, skipping."
      fi
    fi
  done
done

echo "----------------------------------------------------"
echo "🎉 Auto Push Completed at $(date '+%Y-%m-%d %H:%M:%S')"
