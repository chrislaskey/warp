#!/bin/sh
# git-poll.sh — poll a Git remote for new commits and rebuild on changes
#
# Runs as a background process inside the container. When new commits are
# detected on the configured branch, reconciles changed files and runs
# rebuild.sh to create and deploy a new release.
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
RECONCILE_PATHS_FILE="/tmp/git-poll-reconcile-paths.txt"
GIT_POLL_INTERVAL="${GIT_POLL_INTERVAL:-1}"
GIT_REPO_SUBDIR="${GIT_REPO_SUBDIR:-}"

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
# We initialize a fresh repo, add the remote, and fetch the target branch.
#
# Update strategy:
# - Track changed paths incrementally between CURRENT_SHA..LATEST_SHA.
# - Keep a cumulative set of touched paths.
# - Reconcile that path set to LATEST_SHA.
#
# This avoids rebase/reset while still handling later commits that revert
# earlier edits.
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
START_SHA="$CURRENT_SHA"
echo "[git-poll] Baseline commit: ${START_SHA} on ${GIT_BRANCH}"
echo "[git-poll] Polling every ${GIT_POLL_INTERVAL}s for new commits..."
rm -f "$RECONCILE_PATHS_FILE"

REMOTE_PATH_PREFIX=""

detect_remote_path_prefix() {
  if [ -n "$GIT_REPO_SUBDIR" ]; then
    REMOTE_PATH_PREFIX="$GIT_REPO_SUBDIR"
    # Normalize to no leading/trailing slash.
    REMOTE_PATH_PREFIX=$(echo "$REMOTE_PATH_PREFIX" | sed 's#^/*##; s#/*$##')
    echo "[git-poll] Using configured repo subdir prefix: '${REMOTE_PATH_PREFIX}/'"
    return 0
  fi

  # Auto-detect common case: monorepo with app under "example/".
  if git cat-file -e "${CURRENT_SHA}:example/mix.exs" 2>/dev/null; then
    REMOTE_PATH_PREFIX="example"
    echo "[git-poll] Auto-detected repo subdir prefix: '${REMOTE_PATH_PREFIX}/'"
    return 0
  fi

  REMOTE_PATH_PREFIX=""
  echo "[git-poll] Repo root appears to match /app (no path prefix)."
  return 0
}

to_local_path() {
  REMOTE_PATH="$1"

  if [ -z "$REMOTE_PATH_PREFIX" ]; then
    printf "%s\n" "$REMOTE_PATH"
    return 0
  fi

  case "$REMOTE_PATH" in
    "$REMOTE_PATH_PREFIX"/*)
      printf "%s\n" "${REMOTE_PATH#"$REMOTE_PATH_PREFIX"/}"
      return 0
      ;;
    *)
      # Path is outside the selected app subtree; ignore it.
      printf "%s\n" ""
      return 0
      ;;
  esac
}

append_changed_paths() {
  FROM_SHA="$1"
  TO_SHA="$2"
  CHANGED_LIST="/tmp/git-poll-changed-paths.$$"
  MERGED_LIST="/tmp/git-poll-merged-paths.$$"

  # --no-renames emits delete+add paths for renames, which keeps reconciliation simple.
  if ! git diff --name-only --no-renames "$FROM_SHA" "$TO_SHA" > "$CHANGED_LIST"; then
    echo "[git-poll] ERROR: Failed to diff ${FROM_SHA}..${TO_SHA}."
    rm -f "$CHANGED_LIST"
    return 1
  fi

  if [ ! -s "$CHANGED_LIST" ]; then
    rm -f "$CHANGED_LIST"
    return 0
  fi

  FILTERED_LIST="/tmp/git-poll-filtered-paths.$$"
  : > "$FILTERED_LIST"

  while IFS= read -r REMOTE_PATH; do
    [ -z "$REMOTE_PATH" ] && continue
    LOCAL_PATH=$(to_local_path "$REMOTE_PATH")
    [ -z "$LOCAL_PATH" ] && continue
    printf "%s\n" "$LOCAL_PATH" >> "$FILTERED_LIST"
  done < "$CHANGED_LIST"

  if [ ! -s "$FILTERED_LIST" ]; then
    rm -f "$CHANGED_LIST" "$FILTERED_LIST"
    return 0
  fi

  if [ -f "$RECONCILE_PATHS_FILE" ]; then
    cat "$RECONCILE_PATHS_FILE" "$FILTERED_LIST" | sed '/^$/d' | sort -u > "$MERGED_LIST"
    mv "$MERGED_LIST" "$RECONCILE_PATHS_FILE"
  else
    mv "$FILTERED_LIST" "$RECONCILE_PATHS_FILE"
    FILTERED_LIST=""
  fi

  rm -f "$CHANGED_LIST" "$FILTERED_LIST"
  return 0
}

reconcile_tracked_paths() {
  TO_SHA="$1"

  if [ ! -f "$RECONCILE_PATHS_FILE" ] || [ ! -s "$RECONCILE_PATHS_FILE" ]; then
    echo "[git-poll] No changed paths to reconcile."
    return 0
  fi

  PATH_COUNT=$(wc -l < "$RECONCILE_PATHS_FILE" | tr -d ' ')
  echo "[git-poll] Reconciling ${PATH_COUNT} cumulative changed path(s)..."

  FAILED=0
  while IFS= read -r PATHNAME; do
    [ -z "$PATHNAME" ] && continue

    REMOTE_PATH="$PATHNAME"
    if [ -n "$REMOTE_PATH_PREFIX" ]; then
      REMOTE_PATH="$REMOTE_PATH_PREFIX/$PATHNAME"
    fi

    # If the path exists in TO_SHA, write that version to local disk.
    if git cat-file -e "${TO_SHA}:${REMOTE_PATH}" 2>/dev/null; then
      OBJ_TYPE=$(git cat-file -t "${TO_SHA}:${REMOTE_PATH}" 2>/dev/null || true)
      MODE=$(git ls-tree "$TO_SHA" -- "$REMOTE_PATH" | awk 'NR==1 {print $1}')

      mkdir -p "$(dirname "$PATHNAME")"

      if [ "$OBJ_TYPE" = "blob" ] && [ "$MODE" = "120000" ]; then
        # Symlink: blob contents are the symlink target path.
        TARGET=$(git show "${TO_SHA}:${REMOTE_PATH}")
        rm -f "$PATHNAME"
        if ! ln -s "$TARGET" "$PATHNAME"; then
          echo "[git-poll] ERROR: Failed to write symlink: ${PATHNAME}"
          FAILED=1
          break
        fi
      elif [ "$OBJ_TYPE" = "blob" ]; then
        if ! git show "${TO_SHA}:${REMOTE_PATH}" > "$PATHNAME"; then
          echo "[git-poll] ERROR: Failed to write file: ${PATHNAME}"
          FAILED=1
          break
        fi
        if [ "$MODE" = "100755" ]; then
          chmod 755 "$PATHNAME" 2>/dev/null || true
        else
          chmod 644 "$PATHNAME" 2>/dev/null || true
        fi
      else
        echo "[git-poll] WARN: Unsupported object type '${OBJ_TYPE}' for ${REMOTE_PATH}; skipping."
        FAILED=1
        break
      fi
      continue
    fi

    # Otherwise the path was deleted in TO_SHA; remove local file if present.
    rm -f "$PATHNAME" 2>/dev/null || true
  done < "$RECONCILE_PATHS_FILE"

  [ "$FAILED" -eq 0 ]
}

detect_remote_path_prefix

reconcile_changed_paths() {
  FROM_SHA="$1"
  TO_SHA="$2"

  if ! append_changed_paths "$FROM_SHA" "$TO_SHA"; then
    return 1
  fi

  if ! reconcile_tracked_paths "$TO_SHA"; then
    return 1
  fi

  return 0
}

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
    continue
  fi

  echo "$$" > "$REBUILD_LOCK"

  # Reconcile cumulative changed paths to match the latest commit.
  if ! reconcile_changed_paths "$CURRENT_SHA" "$LATEST_SHA"; then
    echo "[git-poll] ERROR: File reconciliation failed."
    rm -f "$REBUILD_LOCK"
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
