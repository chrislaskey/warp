#!/bin/sh
# healthcheck.sh — smoke test for the running Phoenix server
#
# Called by start-wrapper.sh after each server start. Exit 0 = healthy,
# non-zero = unhealthy (wrapper will count this as a failure).
#
# Customize this script to suit your application. Common additions:
#   - Check a specific page that exercises the database
#   - Verify a background job queue is running
#   - Check an external dependency is reachable

PORT="${PORT:-4000}"
URL="http://localhost:${PORT}/"

# Allow up to 20 seconds for the server to start accepting connections
# before we declare it unhealthy. The BEAM + migrations can be slow.
TIMEOUT=20
ELAPSED=0
INTERVAL=2

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$URL" 2>/dev/null) || STATUS="000"

  if [ "$STATUS" = "200" ] || [ "$STATUS" = "301" ] || [ "$STATUS" = "302" ]; then
    echo "[healthcheck] OK (HTTP $STATUS from $URL)"
    exit 0
  fi

  echo "[healthcheck] Waiting for server... (HTTP $STATUS, ${ELAPSED}s elapsed)"
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "[healthcheck] FAILED: server did not respond with a success status within ${TIMEOUT}s (last status: $STATUS)"
exit 1
