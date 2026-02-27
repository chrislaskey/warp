#!/bin/sh
# rebuild.sh — rebuild the Phoenix release and restart the server
#
# Run this script inside the container after making code changes to compile
# a new release, atomically swap the /app/current symlink, and signal the
# start-wrapper.sh to restart the server child.
#
# Usage (from inside the container):
#   /app/bin/rebuild.sh
#
# The container keeps running throughout. There is a brief period of
# downtime while the old server process stops and the new one starts.

set -e

APP_DIR="/app"
RELEASES_DIR="$APP_DIR/releases"
CURRENT_LINK="$APP_DIR/current"
PID_FILE="/tmp/server.pid"
WRAPPER_PID_FILE="/tmp/wrapper.pid"

# ---------------------------------------------------------------------------
# Step 1: Determine the next release version number
# ---------------------------------------------------------------------------

# Find the highest existing numbered release directory.
LAST_VERSION=0
for dir in "$RELEASES_DIR"/*/; do
  name=$(basename "$dir")
  if echo "$name" | grep -qE '^[0-9]+$'; then
    if [ "$name" -gt "$LAST_VERSION" ]; then
      LAST_VERSION="$name"
    fi
  fi
done

NEXT_VERSION=$((LAST_VERSION + 1))
NEXT_RELEASE_DIR="$RELEASES_DIR/$NEXT_VERSION"

echo "[rebuild] Building release version $NEXT_VERSION into $NEXT_RELEASE_DIR..."

# ---------------------------------------------------------------------------
# Step 2: Compile assets and build the release
# ---------------------------------------------------------------------------

cd "$APP_DIR"

echo "[rebuild] Compiling assets..."
mix assets.deploy

echo "[rebuild] Building release..."
mix release --overwrite --path "$NEXT_RELEASE_DIR"

echo "[rebuild] Release built successfully."

# ---------------------------------------------------------------------------
# Step 3: Atomically swap the /app/current symlink
# ---------------------------------------------------------------------------

echo "[rebuild] Swapping symlink: $CURRENT_LINK -> $NEXT_RELEASE_DIR"

# ln -sfn atomically replaces the symlink target.
ln -sfn "$NEXT_RELEASE_DIR" "$CURRENT_LINK"

echo "[rebuild] Symlink updated."

# ---------------------------------------------------------------------------
# Step 4: Signal the wrapper to restart the server child
# ---------------------------------------------------------------------------

# Find the wrapper PID. It writes its own PID to WRAPPER_PID_FILE if set,
# otherwise we find it by looking for the start-wrapper.sh process.
if [ ! -f "$WRAPPER_PID_FILE" ]; then
  echo "[rebuild] ERROR: Wrapper PID file not found at $WRAPPER_PID_FILE."
  echo "[rebuild] Is start-wrapper.sh running? Start the container normally and try again."
  exit 1
fi

WRAPPER_PID=$(cat "$WRAPPER_PID_FILE")

echo "[rebuild] Sending SIGUSR1 to wrapper (pid $WRAPPER_PID) to restart server..."
kill -USR1 "$WRAPPER_PID"

echo "[rebuild] Done. The server will restart momentarily."
echo "[rebuild] To roll back, run: ln -sfn $RELEASES_DIR/$LAST_VERSION $CURRENT_LINK && kill -USR1 $WRAPPER_PID"

# ---------------------------------------------------------------------------
# Step 5: Prune old releases, keeping only the 3 most recent
# ---------------------------------------------------------------------------

KEEP=3

# Collect all numbered release directories sorted numerically (sort -n),
# oldest first. sort -n sorts by integer value so 2 comes before 10.
SORTED=""
for dir in "$RELEASES_DIR"/*/; do
  name=$(basename "$dir")
  if echo "$name" | grep -qE '^[0-9]+$'; then
    SORTED="$SORTED $name"
  fi
done
SORTED=$(echo "$SORTED" | tr ' ' '\n' | grep -v '^$' | sort -n)

# grep -v '^$' above also means an all-empty input produces an empty string,
# so we count only non-empty lines to avoid a spurious count of 1.
TOTAL=$(echo "$SORTED" | grep -c '^[0-9]' || true)

if [ "$TOTAL" -gt "$KEEP" ]; then
  DELETE_COUNT=$((TOTAL - KEEP))
  TO_DELETE=$(echo "$SORTED" | head -n "$DELETE_COUNT")
  for version in $TO_DELETE; do
    echo "[rebuild] Removing old release: $RELEASES_DIR/$version"
    rm -rf "$RELEASES_DIR/$version"
  done
fi
