#!/bin/sh
# git-poll.sh — poll a Git remote for new commits and rebuild on changes
#
# Runs as a background process inside the container. When new commits are
# detected on the configured branch, pulls the changes and runs rebuild.sh
# to create and deploy a new release.
#
# Environment variables:
#   GIT_REPO_URL       — Repository HTTPS URL. Required for polling to start.
#   GIT_BRANCH         — Branch to watch. Required for polling to start.
#   GIT_POLL_INTERVAL  — Seconds between polls (default: 1).
#   GIT_TOKEN          — GitHub access token for private repos (optional).
#                        Fine-grained PAT with Contents:read on the repo is sufficient.
#
# If GIT_REPO_URL or GIT_BRANCH are not set, the script exits immediately
# and the container behaves as if this script doesn't exist.

APP_DIR="/app"
REBUILD_SCRIPT="$APP_DIR/bin/rebuild.sh"
REBUILD_LOCK="/tmp/git-poll-rebuild.lock"
GIT_POLL_INTERVAL="${GIT_POLL_INTERVAL:-1}"

# ---------------------------------------------------------------------------
# Guard: exit early if not configured
# ---------------------------------------------------------------------------

if [ -z "$GIT_REPO_URL" ] || [ -z "$GIT_BRANCH" ]; then
  echo "[git-poll] GIT_REPO_URL or GIT_BRANCH not set. Polling disabled."
  exit 0
fi

# ---------------------------------------------------------------------------
# Build the remote URL (embed token for private repos)
# ---------------------------------------------------------------------------

if [ -n "$GIT_TOKEN" ]; then
  REMOTE_URL=$(echo "$GIT_REPO_URL" | sed "s|https://|https://x-access-token:${GIT_TOKEN}@|")
  echo "[git-poll] Using authenticated URL (token provided)."
else
  REMOTE_URL="$GIT_REPO_URL"
  echo "[git-poll] Using public URL (no token)."
fi

# ---------------------------------------------------------------------------
# Initialize a git repo in /app
#
# The Docker image was built via COPY commands so there is no .git directory.
# We initialize a fresh repo, add the remote, and do a shallow fetch of just
# the target branch. This gives us the minimal history needed to detect and
# pull new commits.
#
# Existing untracked directories (_build/, deps/, releases/, current) are
# not affected by git reset --hard — it only updates tracked files.
# ---------------------------------------------------------------------------

cd "$APP_DIR"

if [ ! -d ".git" ]; then
  echo "[git-poll] Initializing git repository in $APP_DIR..."
  git init -q
  git remote add origin "$REMOTE_URL"
else
  git remote set-url origin "$REMOTE_URL"
fi

git config advice.detachedHead false 2>/dev/null || true

echo "[git-poll] Fetching latest commit on branch '$GIT_BRANCH'..."
if ! git fetch --depth=1 origin "$GIT_BRANCH" 2>&1; then
  echo "[git-poll] ERROR: Initial fetch failed."
  echo "[git-poll] Check that GIT_REPO_URL, GIT_BRANCH, and GIT_TOKEN (if private) are correct."
  exit 1
fi

CURRENT_SHA=$(git rev-parse FETCH_HEAD)
echo "[git-poll] Baseline commit: ${CURRENT_SHA} on ${GIT_BRANCH}"
echo "[git-poll] Polling every ${GIT_POLL_INTERVAL}s for new commits..."

# ---------------------------------------------------------------------------
# Poll loop
# ---------------------------------------------------------------------------

while true; do
  sleep "$GIT_POLL_INTERVAL"

  if ! git fetch --depth=1 origin "$GIT_BRANCH" 2>/dev/null; then
    echo "[git-poll] Fetch failed (network issue?). Will retry next cycle."
    continue
  fi

  LATEST_SHA=$(git rev-parse FETCH_HEAD)

  if [ "$LATEST_SHA" = "$CURRENT_SHA" ]; then
    continue
  fi

  echo "[git-poll] =========================================="
  echo "[git-poll] New commit detected on '$GIT_BRANCH'"
  echo "[git-poll]   was: ${CURRENT_SHA}"
  echo "[git-poll]   now: ${LATEST_SHA}"
  echo "[git-poll] =========================================="

  # Skip if a rebuild is already in progress
  if [ -f "$REBUILD_LOCK" ]; then
    echo "[git-poll] Rebuild already in progress (lock file exists). Skipping this cycle."
    # Still update CURRENT_SHA — when the current rebuild finishes and a newer
    # commit exists, the next cycle will pick it up.
    CURRENT_SHA="$LATEST_SHA"
    continue
  fi

  echo "$$" > "$REBUILD_LOCK"

  # Update the working tree to match the new commit.
  echo "[git-poll] Resetting working tree to ${LATEST_SHA}..."
  if ! git reset --hard FETCH_HEAD; then
    echo "[git-poll] ERROR: git reset --hard failed."
    rm -f "$REBUILD_LOCK"
    CURRENT_SHA="$LATEST_SHA"
    continue
  fi

  # Install/update dependencies in case mix.exs or mix.lock changed.
  # This is fast (no-op) when dependencies haven't changed.
  echo "[git-poll] Running mix deps.get..."
  if ! mix deps.get; then
    echo "[git-poll] WARNING: mix deps.get failed. Attempting rebuild anyway."
  fi

  # Run the rebuild
  echo "[git-poll] Running rebuild..."
  if "$REBUILD_SCRIPT"; then
    echo "[git-poll] Rebuild succeeded for ${LATEST_SHA}."
  else
    echo "[git-poll] Rebuild FAILED for ${LATEST_SHA}."
    echo "[git-poll] The start-wrapper.sh rollback mechanism will handle bad releases."
    echo "[git-poll] Push a fix to trigger another rebuild."
  fi

  CURRENT_SHA="$LATEST_SHA"
  rm -f "$REBUILD_LOCK"
done
