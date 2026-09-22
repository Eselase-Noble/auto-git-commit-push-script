#!/bin/bash
#
# Agent pipeline (macOS).
# For every OPT-IN git repo it runs the full cycle:
#   commit → push branch → open PR → agent code review + issue fixes → merge.
#
# A repo opts in by containing a ".autogit-agent" marker file at its root.
# The marker may be empty, or may set shell overrides sourced per-repo, e.g.:
#     BASE_BRANCH=main
#     MERGE_METHOD=squash          # squash | merge | rebase
#     CLAUDE_FLAGS="--dangerously-skip-permissions"
#
# The agent step uses the `claude` CLI headless (`claude -p`). Because the run
# is unattended it needs a non-interactive permission mode; by default we pass
# --dangerously-skip-permissions. Override via CLAUDE_FLAGS if you want tighter
# control.
#
# Requirements: git, gh (authenticated), claude, jq.
# Intended to be run on-demand OR on a schedule by launchd (see LaunchAgents/).

set -uo pipefail

# --- Environment (launchd runs with a minimal PATH) ---
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Root under which to search for git repositories (override with AUTOGIT_ROOT).
ROOT="${AUTOGIT_ROOT:-$HOME/Projects}"

# Marker file that opts a repo into the full agent pipeline.
MARKER="${AUTOGIT_MARKER:-.autogit-agent}"

# Defaults (a repo's marker file can override any of these).
DEFAULT_MERGE_METHOD="${AUTOGIT_MERGE_METHOD:-squash}"
DEFAULT_CLAUDE_FLAGS="${AUTOGIT_CLAUDE_FLAGS:---dangerously-skip-permissions}"

# Log file lives OUTSIDE the scanned repos so we never commit our own logs.
LOG_DIR="$HOME/Library/Logs/auto-git"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/agent-pipeline.log"
exec >>"$LOG_FILE" 2>&1

STAMP="$(date '+%Y-%m-%d %H:%M:%S')"

echo "===================================================="
echo "=== Starting agent pipeline at $STAMP ==="
echo "Root: $ROOT   Marker: $MARKER"
echo "----------------------------------------------------"

# --- Preflight: required tools -----------------------------------------------
missing=()
for tool in git gh claude jq; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "❌ Missing required tools: ${missing[*]} — aborting."
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "❌ gh is not authenticated (run: gh auth login) — aborting."
  exit 1
fi

# --- Helpers -----------------------------------------------------------------

# Run the agent headlessly on a prompt. Prints its output. Never fails the run.
run_agent() {
  local prompt="$1" flags="$2"
  # shellcheck disable=SC2086
  claude -p "$prompt" $flags 2>&1 || echo "(agent step exited non-zero)"
}

# Ask the agent to write a Conventional-Commits message for the STAGED diff.
# Prints the message on stdout. Falls back to a timestamp message on failure.
generate_commit_message() {
  local flags="$1" fallback="$2" diff prompt msg
  # Cap the diff so the prompt stays reasonable on large changes.
  diff="$(git diff --cached --stat; echo; git diff --cached | head -n 2000)"
  prompt="Write a git commit message that accurately describes ONLY the actual
changes in the diff below. Do not invent, assume, or generalize beyond what the
diff shows. Read every hunk and summarize the real effect of the change.
Rules:
- Start the subject with a standard Conventional Commits type + colon:
  feat:  (new capability)      fix:      (bug fix)
  docs:  (documentation)       refactor: (restructure, no behavior change)
  perf:  (performance)         test:     (tests)
  chore: (tooling/config/misc) style:    (formatting only)
  Pick the ONE type that best matches what the diff actually does.
- Subject line <= 72 chars, imperative mood, no trailing period.
- If several files/areas changed, add a blank line then bullet points ('- ...')
  describing each meaningful change.
- Output ONLY the commit message text. No code fences, no preamble, no quotes.

--- staged changes ---
$diff"
  # Run non-interactively; strip any stray code fences/blank leading lines.
  msg="$(claude -p "$prompt" $flags 2>/dev/null | sed '/^```/d' | sed '/./,$!d')"
  if [ -z "$msg" ]; then
    printf '%s\n' "$fallback"
    return
  fi
  # Guarantee a standard type prefix even if the agent omitted one.
  local subject
  subject="$(printf '%s' "$msg" | head -n1)"
  if ! printf '%s' "$subject" | grep -Eiq '^(feat|fix|docs|refactor|perf|test|chore|style|build|ci)(\(.+\))?!?:'; then
    msg="chore: $msg"
  fi
  printf '%s\n' "$msg"
}

process_repo() {
  local repo="$1"
  cd "$repo" || return

  echo ""
  echo ">>> Repo: $repo"

  # Per-repo overrides from the marker file.
  local BASE_BRANCH="" MERGE_METHOD="$DEFAULT_MERGE_METHOD" CLAUDE_FLAGS="$DEFAULT_CLAUDE_FLAGS"
  if [ -s "$repo/$MARKER" ]; then
    # shellcheck disable=SC1090
    source "$repo/$MARKER"
  fi

  # Must have an origin remote for the PR flow.
  if ! git remote get-url origin >/dev/null 2>&1; then
    echo "🟡 No origin remote, skipping."
    return
  fi

  # Determine base branch (marker override → origin HEAD → current branch).
  if [ -z "$BASE_BRANCH" ]; then
    BASE_BRANCH="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
    [ -z "$BASE_BRANCH" ] && BASE_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  fi
  if [ -z "$BASE_BRANCH" ] || [ "$BASE_BRANCH" = "HEAD" ]; then
    echo "🟡 Could not determine base branch, skipping."
    return
  fi

  # Anything to do? (working-tree changes OR commits already ahead of base)
  git add -A
  local has_worktree_changes=0
  git diff --cached --quiet || has_worktree_changes=1
  if [ "$has_worktree_changes" -eq 0 ]; then
    echo "🟡 No changes to process."
    return
  fi

  # Create a dedicated work branch off the current HEAD.
  local ts branch
  ts="$(date '+%Y%m%d-%H%M%S')"
  branch="agent/auto-$ts"
  if ! git checkout -b "$branch" >/dev/null 2>&1; then
    echo "❌ Could not create branch $branch, skipping."
    return
  fi
  echo "🌿 Work branch: $branch (base: $BASE_BRANCH)"

  # 1) Commit the pending changes with an agent-authored message.
  local commit_msg
  commit_msg="$(generate_commit_message "$CLAUDE_FLAGS" "Auto Commit: $STAMP")"
  echo "📝 Commit message: $(printf '%s' "$commit_msg" | head -n1)"
  if git commit -m "$commit_msg" >/dev/null; then
    echo "✅ Committed changes."
  else
    echo "❌ Commit failed, aborting repo."
    git checkout - >/dev/null 2>&1
    return
  fi

  # 2) Push the branch.
  if ! git push -u origin "$branch" >/dev/null 2>&1; then
    echo "❌ Push failed — check credentials/remote permissions. Aborting repo."
    return
  fi
  echo "⬆️  Pushed $branch."

  # 3) Open a PR into the base branch.
  local pr_url pr_num pr_title
  pr_title="$(printf '%s' "$commit_msg" | head -n1)"
  pr_url="$(gh pr create --base "$BASE_BRANCH" --head "$branch" \
              --title "$pr_title" \
              --body "Automated changes committed by the agent pipeline on $STAMP.

$commit_msg" \
              2>&1)"
  if [ $? -ne 0 ] || [ -z "$pr_url" ]; then
    echo "❌ PR creation failed: $pr_url"
    return
  fi
  pr_num="$(gh pr view "$branch" --json number --jq .number 2>/dev/null)"
  echo "🔀 Opened PR #$pr_num: $pr_url"

  # 4) Agent code review + issue resolution (the agent edits & commits fixes).
  echo "🤖 Running agent review + fixes…"
  local review_prompt review_out
  review_prompt="You are reviewing a pull request in this repository.
The changes are on the current branch '$branch' relative to base '$BASE_BRANCH'.
Steps:
1. Run: git diff origin/$BASE_BRANCH...HEAD  to see the changes.
2. Review for correctness bugs, security issues, and obvious breakage.
3. Fix any real issues you find directly in the files.
4. If you made fixes, stage and commit them with: git commit -am 'Agent review: resolve issues'.
5. Do NOT push, do NOT merge, do NOT open PRs — the surrounding script handles that.
Finally, print a concise review summary: what you checked and what you fixed (or 'No issues found')."
  review_out="$(run_agent "$review_prompt" "$CLAUDE_FLAGS")"
  echo "----- agent review summary -----"
  echo "$review_out"
  echo "--------------------------------"

  # Post the review as a PR comment (best-effort).
  printf '%s\n' "$review_out" | gh pr comment "$pr_num" --body-file - >/dev/null 2>&1 \
    && echo "💬 Posted review as PR comment." \
    || echo "🟡 Could not post PR comment (continuing)."

  # 5) Push any fixes the agent committed.
  local ahead
  ahead="$(git rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 0)"
  if [ "${ahead:-0}" -gt 0 ]; then
    if git push origin "$branch" >/dev/null 2>&1; then
      echo "⬆️  Pushed agent fixes ($ahead commit(s))."
    else
      echo "❌ Failed to push agent fixes."
    fi
  else
    echo "🟢 Agent made no code changes."
  fi

  # 6) Merge the PR into the base branch, then clean up.
  if gh pr merge "$pr_num" --"$MERGE_METHOD" --delete-branch >/dev/null 2>&1; then
    echo "🎯 Merged PR #$pr_num ($MERGE_METHOD) and deleted branch."
  else
    echo "❌ Merge failed for PR #$pr_num — leaving it open for manual review."
  fi

  # Return to the base branch and sync.
  git checkout "$BASE_BRANCH" >/dev/null 2>&1 && git pull --ff-only origin "$BASE_BRANCH" >/dev/null 2>&1
}

# --- Discover opt-in repos and process each ----------------------------------
find "$ROOT" -type d \( \
      -name node_modules -o -name vendor -o -name Pods -o -name .venv \
      -o -name venv -o -name .tox -o -name DerivedData -o -name .next \
      -o -name build -o -name dist \
    \) -prune -o -type d -name .git -print 2>/dev/null | while IFS= read -r gitdir; do

  repo="$(dirname "$gitdir")"
  [ -e "$repo/$MARKER" ] || continue   # opt-in only
  process_repo "$repo"
done

echo ""
echo "🎉 Agent pipeline finished at $(date '+%Y-%m-%d %H:%M:%S')"
