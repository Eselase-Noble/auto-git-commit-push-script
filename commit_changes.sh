#!/bin/bash
#
# Auto-commit script.
# Discovers every git repo under $ROOT and commits any local changes, using an
# agent-authored Conventional Commit message that describes the actual diff.
# Falls back to a timestamp message if the agent is unavailable or errors.
# Cross-platform: macOS/Linux natively, Windows via WSL or Git Bash.
# Intended to be run on a schedule (launchd/cron/systemd — see SCHEDULING.md).

# --- Environment -------------------------------------------------------------
# Schedulers run with a minimal PATH, so prepend common install locations
# across macOS (Homebrew) and Linux; missing dirs are skipped.
for d in /opt/homebrew/bin /usr/local/bin /usr/bin /bin /usr/sbin /sbin \
         "$HOME/.local/bin" /home/linuxbrew/.linuxbrew/bin; do
  [ -d "$d" ] && case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
done
export PATH

# Root under which to search for git repositories (override with AUTOGIT_ROOT).
ROOT="${AUTOGIT_ROOT:-$HOME/Projects}"

# Flags for the headless agent (override with AUTOGIT_CLAUDE_FLAGS).
CLAUDE_FLAGS="${AUTOGIT_CLAUDE_FLAGS:---dangerously-skip-permissions}"

# Log file lives OUTSIDE the scanned repos so we never commit our own logs.
# OS-appropriate location; override with AUTOGIT_LOG_DIR.
if [ -n "${AUTOGIT_LOG_DIR:-}" ]; then
  LOG_DIR="$AUTOGIT_LOG_DIR"
elif [ "$(uname -s)" = "Darwin" ]; then
  LOG_DIR="$HOME/Library/Logs/auto-git"
else
  LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/auto-git"
fi
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/commit.log"
exec >>"$LOG_FILE" 2>&1

FALLBACK_MESSAGE="Auto Commit: $(date '+%Y-%m-%d %H:%M:%S')"

echo "===================================================="
echo "=== Starting auto-commit at $(date '+%Y-%m-%d %H:%M:%S') ==="
echo "Root: $ROOT"
echo "----------------------------------------------------"

# Is the agent available for message generation?
HAVE_CLAUDE=0
command -v claude >/dev/null 2>&1 && HAVE_CLAUDE=1
[ "$HAVE_CLAUDE" -eq 1 ] || echo "🟡 'claude' not found — using fallback timestamp messages."

# Ask the agent to write a Conventional-Commits message for the STAGED diff.
# Prints the message; falls back to the timestamp message on any failure.
generate_commit_message() {
  if [ "$HAVE_CLAUDE" -ne 1 ]; then
    printf '%s\n' "$FALLBACK_MESSAGE"
    return
  fi
  local diff prompt msg subject
  diff="$(git diff --cached --stat; echo; git diff --cached | head -n 2000)"
  prompt="Write a git commit message that accurately describes ONLY the actual
changes in the diff below. Do not invent, assume, or generalize beyond what the
diff shows. Read every hunk and summarize the real effect of the change.
Rules:
- Start the subject with a standard Conventional Commits type + colon:
  feat: fix: docs: refactor: perf: test: chore: style: build: ci:
  Pick the ONE type that best matches what the diff actually does.
- Subject line <= 72 chars, imperative mood, no trailing period.
- If several files/areas changed, add a blank line then bullet points ('- ...').
- The FIRST line of your output MUST be the subject line itself. Do NOT prefix
  it with anything like 'Here is', 'The commit message:', quotes, or code fences.

--- staged changes ---
$diff"
  local raw n msg
  # shellcheck disable=SC2086
  raw="$(claude -p "$prompt" $CLAUDE_FLAGS 2>/dev/null | sed '/^```/d')"
  # Prefer the first real Conventional-Commit line, dropping any preamble before
  # it (e.g. "The commit message:"). Take from that line to the end.
  n="$(printf '%s\n' "$raw" | grep -niE '^(feat|fix|docs|refactor|perf|test|chore|style|build|ci)(\(.+\))?!?:' | head -n1 | cut -d: -f1)"
  if [ -n "$n" ]; then
    msg="$(printf '%s\n' "$raw" | tail -n +"$n")"
  else
    # No typed line found: strip common preamble + leading blanks, keep the
    # first meaningful line, and guarantee a standard prefix.
    msg="$(printf '%s\n' "$raw" \
            | sed -E '/^[[:space:]]*(sure|okay|ok|here.?s?( is| are)?|the commit message|commit message)[[:space:]:,.-]*$/Id' \
            | sed '/./,$!d' | head -n1)"
    [ -n "$msg" ] && msg="chore: $msg"
  fi
  # (git strips trailing blank lines from the message itself.)
  if [ -z "$msg" ]; then
    printf '%s\n' "$FALLBACK_MESSAGE"
    return
  fi
  printf '%s\n' "$msg"
}

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
    msg="$(generate_commit_message)"
    echo "📝 [$repo] $(printf '%s' "$msg" | head -n1)"
    if git commit -m "$msg" >/dev/null; then
      echo "✅ Committed: $repo"
    else
      echo "❌ Commit FAILED: $repo"
    fi
  fi
done

echo "🎉 Auto-commit finished at $(date '+%Y-%m-%d %H:%M:%S')"
