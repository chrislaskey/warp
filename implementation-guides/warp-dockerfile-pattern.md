# Warp Dockerfile Pattern: LLM Migration Guide

This document describes the Warp development Dockerfile pattern for Elixir Phoenix applications. It is written for LLMs that need to apply this pattern to an existing Phoenix project.

---

## What This Pattern Does

A standard `flyctl`-generated Dockerfile uses a **multi-stage build**: a builder stage compiles the release, and a minimal runner stage copies only the compiled artifacts. This is ideal for production (small image, no build tools) but makes in-container iteration impossible.

This pattern transforms that Dockerfile into a **single-stage development image** that:

1. Keeps all build tools available at runtime (`mix`, `hex`, `rebar`, `apt`, `git`, etc.)
2. Uses `tini` as PID 1 for correct signal handling and zombie process reaping
3. Runs the Phoenix server via a **wrapper script** (not directly as CMD) so the container stays alive across server restarts
4. Stores releases in **versioned directories** under `/app/releases/` with an `/app/current` symlink, enabling atomic rollback
5. Provides a `rebuild.sh` script that compiles a new release, swaps the symlink, and restarts the server — all without stopping the container

Security hardening lines (`chown nobody`, `USER nobody`) are **commented out** rather than removed, so they can be restored when converting back to a production image.

---

## Files Involved

```
<project>/
├── Dockerfile                    # modified (single-stage, tini, wrapper)
├── bin/
│   ├── start-wrapper.sh          # new: PID 2 restart loop with health check and rollback
│   ├── healthcheck.sh            # new: smoke test called after each server start
│   └── rebuild.sh                # new: developer rebuild command
```

The original multi-stage Dockerfile should be preserved as `Dockerfile.original` or `Dockerfile.multistage` for reference.

---

## Step 1: Collapse to a Single Stage

### Before (multi-stage)

```dockerfile
ARG BUILDER_IMAGE="docker.io/hexpm/elixir:..."
ARG RUNNER_IMAGE="docker.io/debian:..."

FROM ${BUILDER_IMAGE} AS builder
# ... build steps ...
RUN mix release

FROM ${RUNNER_IMAGE} AS final
RUN apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates
COPY --from=builder --chown=nobody:root /app/_build/prod/rel/myapp ./
USER nobody
CMD ["/app/bin/server"]
```

### After (single-stage)

- Remove the `ARG RUNNER_IMAGE` line
- Remove the `FROM ${RUNNER_IMAGE} AS final` stage entirely
- Change `FROM ${BUILDER_IMAGE} AS builder` to just `FROM ${BUILDER_IMAGE}` (no `AS builder`)
- Add runtime packages (`libstdc++6`, `openssl`, `libncurses6`, `locales`, `ca-certificates`) to the same `apt-get install` block as the build packages
- Add `tini` to the `apt-get install` block
- Use `apt-get clean` instead of `rm -rf /var/lib/apt/lists/*` so `apt-get install` keeps working at runtime
- Remove the `COPY --from=builder` line (there is no longer a separate stage to copy from)
- Comment out (do not delete) `USER nobody` and `RUN chown nobody /app`

### Resulting apt-get block

```dockerfile
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    libstdc++6 \
    openssl \
    libncurses6 \
    locales \
    ca-certificates \
    tini \
  && apt-get clean
```

---

## Step 2: Build the Initial Release into a Versioned Directory

Replace the plain `mix release` call with one that outputs to a versioned path, then create the `/app/current` symlink.

### Before

```dockerfile
RUN mix release
```

### After

```dockerfile
RUN mix release --path /app/releases/1 \
  && ln -s /app/releases/1 /app/current
```

The `--path` flag tells Mix to write the release to `/app/releases/1` instead of `_build/prod/rel/<appname>`. Subsequent rebuilds inside the container will write to `/app/releases/2`, `/app/releases/3`, etc.

---

## Step 3: Copy the Wrapper Scripts

Add these lines after the release build step:

```dockerfile
COPY bin/start-wrapper.sh /app/bin/start-wrapper.sh
COPY bin/healthcheck.sh /app/bin/healthcheck.sh
COPY bin/rebuild.sh /app/bin/rebuild.sh
RUN chmod +x /app/bin/start-wrapper.sh /app/bin/healthcheck.sh /app/bin/rebuild.sh
```

The `bin/` directory lives at the root of the project (alongside `lib/`, `config/`, etc.).

---

## Step 4: Update ENTRYPOINT and CMD

### Before

```dockerfile
# ENTRYPOINT ["/tini", "--"]
CMD ["/app/bin/server"]
```

### After

```dockerfile
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/bin/start-wrapper.sh"]
```

`tini` is PID 1. `start-wrapper.sh` is its direct child (PID 2). The Phoenix server is a grandchild process, which means it can be killed and restarted without affecting PID 1 or PID 2.

---

## Step 5: Create `bin/start-wrapper.sh`

Create this file at `<project>/bin/start-wrapper.sh`:

```sh
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

# Number of consecutive failures before rolling back to the previous release.
FAILURE_THRESHOLD=3

echo $$ > "$WRAPPER_PID_FILE"

current_release_version() {
  basename "$(readlink "$CURRENT_LINK")"
}

previous_release_version() {
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

cleanup() {
  echo "[wrapper] Shutdown signal received."
  stop_server
  echo "[wrapper] Exiting."
  exit 0
}

restart_server() {
  echo "[wrapper] Restart signal received (new release deploy)."
  stop_server
  CONSECUTIVE_FAILURES=0
  TRACKED_VERSION=$(current_release_version)
  echo "[wrapper] Failure counter reset for release $TRACKED_VERSION."
}

trap cleanup TERM INT
trap restart_server USR1

CONSECUTIVE_FAILURES=0
TRACKED_VERSION=$(current_release_version)

echo "[wrapper] Starting. Current release: $TRACKED_VERSION (failure threshold: $FAILURE_THRESHOLD)"

while true; do
  RELEASE_BIN="$CURRENT_LINK/bin/server"
  LOOP_VERSION=$(current_release_version)

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

  # Run the health check in a subshell. set +e is required so that a non-zero
  # exit from healthcheck.sh does not abort the subshell before it can write
  # the result file and kill the server. Without set +e, the wrapper would
  # block on `wait "$SERVER_PID"` forever because the server is never killed.
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

  wait "$SERVER_PID" || true
  SERVER_EXIT=$?

  kill "$HEALTHCHECK_PID" 2>/dev/null || true
  wait "$HEALTHCHECK_PID" 2>/dev/null || true

  rm -f "$SERVER_PID_FILE"

  HEALTHCHECK_EXIT=0
  if [ -f "$HEALTHCHECK_RESULT_FILE" ]; then
    HEALTHCHECK_EXIT=$(cat "$HEALTHCHECK_RESULT_FILE")
  else
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
```

---

## Step 6: Create `bin/healthcheck.sh`

Create this file at `<project>/bin/healthcheck.sh`:

```sh
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

# Allow up to 30 seconds for the server to start accepting connections
# before we declare it unhealthy. The BEAM + migrations can be slow.
TIMEOUT=30
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
```

> **Note on `STATUS` assignment:** The `|| STATUS="000"` must be written as a separate assignment outside the command substitution (`$(...)`) rather than inside it with `|| echo "000"`. When curl cannot connect it still writes `000` via `-w "%{http_code}"`, so `|| echo "000"` inside `$(...)` would append a second `000`, producing `000000`. The form above overwrites `STATUS` cleanly on failure.

---

## Step 8: Create `bin/rebuild.sh`

Create this file at `<project>/bin/rebuild.sh`:

```sh
#!/bin/sh
# rebuild.sh — rebuild the Phoenix release and restart the server
#
# Run inside the container after making code changes.
# Compiles a new release, swaps /app/current, signals the wrapper to restart.
#
# Usage: /app/bin/rebuild.sh

set -e

APP_DIR="/app"
RELEASES_DIR="$APP_DIR/releases"
CURRENT_LINK="$APP_DIR/current"
PID_FILE="/tmp/server.pid"

# Determine next version number
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

cd "$APP_DIR"

echo "[rebuild] Compiling assets..."
mix assets.deploy

echo "[rebuild] Building release..."
mix release --overwrite --path "$NEXT_RELEASE_DIR"

echo "[rebuild] Swapping symlink: $CURRENT_LINK -> $NEXT_RELEASE_DIR"
ln -sfn "$NEXT_RELEASE_DIR" "$CURRENT_LINK"

# Find the wrapper process and signal it to restart
WRAPPER_PID=$(pgrep -f "start-wrapper.sh" | head -1)

if [ -z "$WRAPPER_PID" ]; then
  echo "[rebuild] WARNING: Could not find wrapper process. Restart manually."
  exit 1
fi

echo "[rebuild] Sending SIGUSR1 to wrapper (pid $WRAPPER_PID)..."
kill -USR1 "$WRAPPER_PID"

echo "[rebuild] Done. Server restarting."
echo "[rebuild] Rollback: ln -sfn $RELEASES_DIR/$LAST_VERSION $CURRENT_LINK && kill -USR1 $WRAPPER_PID"
```

---

## Complete Dockerfile Reference

Below is the full resulting Dockerfile for a Phoenix app named `example`. Replace `example` with your actual app name where it appears in `config/${MIX_ENV}.exs` and similar paths — the `mix release` command and `bin/server` path are derived from the `:app` key in `mix.exs`.

```dockerfile
# Single-stage Dockerfile for iterative development on remote Elixir containers.
ARG ELIXIR_VERSION=1.19.2
ARG OTP_VERSION=27.1.3
ARG DEBIAN_VERSION=trixie-20260202-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE}

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    libstdc++6 \
    openssl \
    libncurses6 \
    locales \
    ca-certificates \
    tini \
  && apt-get clean

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

RUN mix local.hex --force \
  && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv
COPY lib lib

RUN mix compile

COPY assets assets

RUN mix assets.deploy

COPY config/runtime.exs config/

COPY rel rel

RUN mix release --path /app/releases/1 \
  && ln -s /app/releases/1 /app/current

COPY bin/start-wrapper.sh /app/bin/start-wrapper.sh
COPY bin/healthcheck.sh /app/bin/healthcheck.sh
COPY bin/rebuild.sh /app/bin/rebuild.sh
RUN chmod +x /app/bin/start-wrapper.sh /app/bin/healthcheck.sh /app/bin/rebuild.sh

# --- Security hardening (commented out for iterative development) ---
# RUN chown nobody /app
# USER nobody
# --- End security hardening ---

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/bin/start-wrapper.sh"]
```

---

## Developer Workflow (Inside the Container)

After the container is running, the iterative development loop is:

```sh
# 1. Edit source files (via SSH, fly ssh console, docker exec, etc.)
#    e.g. edit /app/lib/example_web/controllers/page_controller.ex

# 2. Run the rebuild script
/app/bin/rebuild.sh

# 3. The script will:
#    - Run mix assets.deploy
#    - Build a new release into /app/releases/2 (or 3, 4, ...)
#    - Swap /app/current -> /app/releases/2
#    - Send SIGUSR1 to start-wrapper.sh
#    - The wrapper kills the old server and starts a new one via /app/current/bin/server
```

To roll back to the previous release:

```sh
ln -sfn /app/releases/1 /app/current
kill -USR1 $(pgrep -f "start-wrapper.sh")
```

---

## Key Design Decisions

| Decision | Rationale |
|---|---|
| Single `FROM` using the Elixir builder image | Keeps `mix`, `hex`, `rebar`, `git`, and `apt` available at runtime for in-container rebuilds |
| `apt-get clean` instead of `rm -rf /var/lib/apt/lists/*` | Preserves the ability to run `apt-get install` later without `apt-get update` |
| `tini` as PID 1 | Correctly forwards SIGTERM to child processes and reaps zombie processes — critical when the server is a grandchild, not PID 1 |
| `start-wrapper.sh` as PID 2 (not the server directly) | Allows the server process to be killed and restarted without the container exiting |
| `SIGUSR1` for restart, `SIGTERM` for shutdown | Clean separation: `SIGUSR1` is the "reload" signal (used by rebuild.sh), `SIGTERM` is the "stop container" signal (used by Docker/Fly.io) |
| Versioned release directories + symlink | Atomic switchover — the old release stays on disk until the new one is confirmed started. Enables one-command rollback |
| Health check subshell uses `set +e` | The wrapper uses `set -e` globally. Without `set +e` inside the subshell, a non-zero exit from `healthcheck.sh` aborts the subshell before it can write the result file or kill the server — leaving the server running and `wait` blocked forever. |
| `STATUS` fallback assigned outside `$(...)` | `curl` writes `000` via `-w "%{http_code}"` even on connection failure, then exits non-zero. `|| echo "000"` inside `$(...)` appends a second `000`, producing `000000`. Assigning the fallback outside (`|| STATUS="000"`) overwrites the variable cleanly. |
| Security hardening commented out, not deleted | Makes it easy to restore production security when converting back to a multi-stage build |

---

## Adapting to a Different App Name

The only place the app name appears in the Dockerfile is in the `config/${MIX_ENV}.exs` COPY line. The `mix release` command infers the app name from `mix.exs`. The `bin/server` path inside the release is always `bin/server` regardless of app name (it is generated by `mix phx.gen.release`).

The `start-wrapper.sh` and `rebuild.sh` scripts use `/app/current/bin/server` which is app-name-agnostic via the symlink.

No changes to the scripts are needed when adapting to a different app name.
