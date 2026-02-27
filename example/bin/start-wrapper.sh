#!/bin/sh
# start-wrapper.sh — entrypoint wrapper with health check and auto-rollback
#
# This script is the direct child of tini (PID 1). It runs the Phoenix
# release server as a child process in a loop so the container stays alive
# across release rebuilds and restarts.
#
# The server is always started via the /app/current symlink. To deploy a new
# release, rebuild.sh updates the symlink and sends SIGUSR1 to this process.
#
# Failure detection and rollback:
#   After each server start, healthcheck.sh is run. A "failure" is counted
#   when either:
#     - The server process exits unexpectedly (crash), OR
#     - healthcheck.sh returns a non-zero exit code
#   Failures are tracked per release. When FAILURE_THRESHOLD consecutive
#   failures occur for the current release, the wrapper rolls back to the
#   previous numbered release directory and resets the failure counter.
#   If there is no previous release to roll back to, the wrapper keeps
#   retrying the current release (standard restart loop behaviour).
#
# Signal behaviour (with tini as PID 1):
#   SIGTERM  — tini forwards to this script, which stops the server child
#              and exits cleanly (container stops).
#   SIGUSR1  — triggers a graceful restart of the server child only
#              (container keeps running). Used by rebuild.sh.

set -e

WRAPPER_PID_FILE="/tmp/wrapper.pid"
SERVER_PID_FILE="/tmp/server.pid"
RELEASES_DIR="/app/releases"
CURRENT_LINK="/app/current"
HEALTHCHECK="/app/bin/healthcheck.sh"
GIT_POLL_SCRIPT="/app/bin/git-poll.sh"
GIT_POLL_PID=""

# Number of consecutive failures before rolling back to the previous release.
FAILURE_THRESHOLD=3

echo $$ > "$WRAPPER_PID_FILE"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

current_release_version() {
  # Resolve the /app/current symlink to its target directory name (a number).
  basename "$(readlink "$CURRENT_LINK")"
}

previous_release_version() {
  # Find the highest-numbered release directory that is older than the current.
  current=$(current_release_version)
  prev=0
  for dir in "$RELEASES_DIR"/*/; do
    name=$(basename "$dir")
    if echo "$name" | grep -qE '^[0-9]+$'; then
      if [ "$name" -lt "$current" ] && [ "$name" -gt "$prev" ]; then
        prev="$name"
      fi
    fi
  done
  # Return empty string if no previous release exists.
  [ "$prev" -gt 0 ] && echo "$prev" || echo ""
}

stop_server() {
  if [ -f "$SERVER_PID_FILE" ]; then
    SERVER_PID=$(cat "$SERVER_PID_FILE")
    echo "[wrapper] Stopping server (pid $SERVER_PID)..."
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    rm -f "$SERVER_PID_FILE"
  fi
}

rollback() {
  prev=$(previous_release_version)
  if [ -z "$prev" ]; then
    echo "[wrapper] ROLLBACK SKIPPED: no previous release found. Retrying current release."
    return 1
  fi
  echo "[wrapper] *** ROLLING BACK to release $prev ***"
  ln -sfn "$RELEASES_DIR/$prev" "$CURRENT_LINK"
  echo "[wrapper] Symlink updated: $CURRENT_LINK -> $RELEASES_DIR/$prev"
  return 0
}

# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------

stop_git_poll() {
  if [ -n "$GIT_POLL_PID" ]; then
    echo "[wrapper] Stopping git-poll (pid $GIT_POLL_PID)..."
    kill "$GIT_POLL_PID" 2>/dev/null || true
    wait "$GIT_POLL_PID" 2>/dev/null || true
    GIT_POLL_PID=""
  fi
}

cleanup() {
  echo "[wrapper] Shutdown signal received."
  stop_git_poll
  stop_server
  echo "[wrapper] Exiting."
  exit 0
}

# SIGUSR1 is sent by rebuild.sh after swapping the symlink to a new release.
# Reset the failure counter so the new release gets a clean slate.
restart_server() {
  echo "[wrapper] Restart signal received (new release deploy)."
  stop_server
  CONSECUTIVE_FAILURES=0
  TRACKED_VERSION=$(current_release_version)
  echo "[wrapper] Failure counter reset for release $TRACKED_VERSION."
  # The main loop will immediately start a new server child.
}

trap cleanup TERM INT
trap restart_server USR1

# ---------------------------------------------------------------------------
# Start git polling (if configured via GIT_REPO_URL and GIT_BRANCH env vars)
# ---------------------------------------------------------------------------

if [ -n "$GIT_REPO_URL" ] && [ -n "$GIT_BRANCH" ]; then
  echo "[wrapper] Git polling configured: branch '$GIT_BRANCH' from $GIT_REPO_URL"
  "$GIT_POLL_SCRIPT" &
  GIT_POLL_PID=$!
  echo "[wrapper] git-poll started (pid $GIT_POLL_PID)."
else
  echo "[wrapper] Git polling not configured (set GIT_REPO_URL and GIT_BRANCH to enable)."
fi

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

CONSECUTIVE_FAILURES=0
TRACKED_VERSION=$(current_release_version)

echo "[wrapper] Starting. Current release: $TRACKED_VERSION (failure threshold: $FAILURE_THRESHOLD)"

while true; do
  RELEASE_BIN="$CURRENT_LINK/bin/server"
  LOOP_VERSION=$(current_release_version)

  # If the symlink changed since we last checked (e.g. manual rollback),
  # reset the failure counter for the newly active release.
  if [ "$LOOP_VERSION" != "$TRACKED_VERSION" ]; then
    echo "[wrapper] Release changed to $LOOP_VERSION. Resetting failure counter."
    CONSECUTIVE_FAILURES=0
    TRACKED_VERSION="$LOOP_VERSION"
  fi

  echo "[wrapper] Starting server (release $TRACKED_VERSION, failure count: $CONSECUTIVE_FAILURES)..."
  "$RELEASE_BIN" &
  SERVER_PID=$!
  echo "$SERVER_PID" > "$SERVER_PID_FILE"
  echo "[wrapper] Server started (pid $SERVER_PID)."

  # Run the health check in the background. If it fails, it kills the server
  # so that the wait below unblocks — otherwise a running-but-unhealthy server
  # would block the wrapper forever.
  HEALTHCHECK_RESULT_FILE="/tmp/healthcheck.result"
  rm -f "$HEALTHCHECK_RESULT_FILE"
  (
    set +e
    sh "$HEALTHCHECK"
    HC_EXIT=$?
    echo "$HC_EXIT" > "$HEALTHCHECK_RESULT_FILE"
    if [ "$HC_EXIT" -ne 0 ] && [ -f "$SERVER_PID_FILE" ]; then
      echo "[wrapper] Health check failed — stopping server to trigger restart."
      kill "$(cat "$SERVER_PID_FILE")" 2>/dev/null || true
    fi
  ) &
  HEALTHCHECK_PID=$!

  # Wait for the server process. This is interrupted by signal traps, and also
  # by the health check killing the server on failure.
  wait "$SERVER_PID" || true
  SERVER_EXIT=$?

  # Kill the health check if the server already exited before it finished.
  kill "$HEALTHCHECK_PID" 2>/dev/null || true
  wait "$HEALTHCHECK_PID" 2>/dev/null || true

  rm -f "$SERVER_PID_FILE"

  # Determine whether this attempt was healthy or a failure.
  HEALTHCHECK_EXIT=0
  if [ -f "$HEALTHCHECK_RESULT_FILE" ]; then
    HEALTHCHECK_EXIT=$(cat "$HEALTHCHECK_RESULT_FILE")
  else
    # Health check didn't finish — server crashed before it could complete.
    HEALTHCHECK_EXIT=1
  fi

  if [ "$SERVER_EXIT" -ne 0 ] || [ "$HEALTHCHECK_EXIT" -ne 0 ]; then
    CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
    echo "[wrapper] Failure detected (crash=$SERVER_EXIT, healthcheck=$HEALTHCHECK_EXIT). Consecutive failures: $CONSECUTIVE_FAILURES/$FAILURE_THRESHOLD"

    if [ "$CONSECUTIVE_FAILURES" -ge "$FAILURE_THRESHOLD" ]; then
      echo "[wrapper] Failure threshold reached."
      if rollback; then
        CONSECUTIVE_FAILURES=0
        TRACKED_VERSION=$(current_release_version)
        echo "[wrapper] Now running release $TRACKED_VERSION."
      fi
    fi
  else
    if [ "$CONSECUTIVE_FAILURES" -ne 0 ]; then
      echo "[wrapper] Server healthy. Resetting failure counter."
      CONSECUTIVE_FAILURES=0
    fi
  fi

  echo "[wrapper] Restarting in 1s..."
  sleep 1
done
