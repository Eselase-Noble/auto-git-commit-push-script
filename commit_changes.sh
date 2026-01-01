#!/bin/bash

# Directories to search for git repositories
SEARCH_DIRS=(
    "/home/nobleson/GLNS/PROJECTS"
    "/home/nobleson/Projects/PERSONAL"
    "/home/nobleson/Nobleson"
    "/home/nobleson/SENDIT-GH"
    "/home/nobleson/Projects/STARTUPS/AfrikodeLab"
    "/home/nobleson/Projects/PERSONAL/AI"
)

# Commit message with current date and time
COMMIT_MESSAGE="Auto Commit: $(date '+%Y-%m-%d %H:%M:%S')"

echo "Starting auto-commit process..."
echo "Commit message: $COMMIT_MESSAGE"
echo "----------------------------------------------------"

# Loop through each base directory
for BASE_DIR in "${SEARCH_DIRS[@]}"; do
  echo "Searching in: $BASE_DIR"

  # Loop through each subdirectory inside the base directory
  for dir in "$BASE_DIR"/*; do
    if [ -d "$dir/.git" ]; then
      echo "→ Processing Git repository in: $dir"
      cd "$dir" || continue

      # Add and commit changes if any
      git add .
      if ! git diff --cached --quiet; then
        git commit -m "$COMMIT_MESSAGE"
        echo "✅ Changes committed in $dir"
      else
        echo "🟡 No changes detected in $dir"
      fi
      echo "----------------------------------------------------"
    fi
  done
done

echo "🎉 All done!"
