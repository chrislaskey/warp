# Warp GitHub Polling Pattern: LLM Migration Guide

This document describes Pattern 2 for Warp-style remote iteration: polling a GitHub branch from inside the running container and applying file-level reconciliation before rebuilding. It builds on Pattern 1 from `implementation-guides/warp-dockerfile-pattern.md`.

---

## Prerequisite

Apply Pattern 1 first:

- single-stage runtime image with build tools available
- `start-wrapper.sh` entrypoint loop using `/app/current`
- `rebuild.sh` for atomic release swaps and restart signaling

Pattern 2 assumes those pieces already exist and only adds automated source synchronization.

---

## What This Pattern Does

Pattern 2 turns the container into a self-updating development target:

1. Poll a remote branch (`GIT_REPO_URL` + `GIT_BRANCH`) on a short interval
2. Detect new commits
3. Reconcile only tracked file paths that changed across observed commits
4. Run `mix deps.get` and then `rebuild.sh`
5. Let `start-wrapper.sh` restart/rollback using existing Pattern 1 behavior

Developer loop:

```sh
# local machine
git commit -m "change"
git push

# container
# polls -> reconciles files -> rebuilds -> wrapper restarts
```

---

## Why File Reconciliation (Not Rebase/Reset)

In this pattern, avoid `git rebase` in the container update path. It can destabilize mtimes and build state in iterative runtime rebuild workflows.

Instead:

- maintain a cumulative set of changed paths
- write only those paths to disk from the latest fetched commit
- remove paths that were deleted upstream

This keeps behavior explicit and easy to reason about when the container has no checked-out branch and starts from a Docker `COPY`-based filesystem.

---

## Files Involved

```text
<project>/
├── bin/
│   ├── start-wrapper.sh          # modified: starts git-poll in background
│   └── git-poll.sh               # new: poll + reconcile + rebuild
├── Dockerfile                    # modified: copy git-poll.sh and chmod +x
└── docker.run.sh                 # modified: pass git polling env vars
```

---

## Step 1: Add `bin/git-poll.sh`

Create `bin/git-poll.sh` and make it executable. Core behavior should include:

- exit early when polling env vars are absent
- initialize `.git` inside `/app` if needed
- fetch branch head (`git fetch --depth=1 origin "$GIT_BRANCH"`)
- track `CURRENT_SHA`
- on new SHA:
  - gather changed paths between `CURRENT_SHA..LATEST_SHA`
  - merge into a cumulative changed-path file (e.g. `/tmp/git-poll-reconcile-paths.txt`)
  - reconcile cumulative paths to `LATEST_SHA`
  - run `mix deps.get`
  - run `bin/rebuild.sh`
  - update `CURRENT_SHA`

Recommended env vars:

| Variable | Required | Default | Notes |
|---|---|---|---|
| `GIT_REPO_URL` | Yes* | — | HTTPS clone URL |
| `GIT_BRANCH` | Yes* | — | branch to poll |
| `GIT_POLL_INTERVAL` | No | `1` | poll interval in seconds |
| `GIT_TOKEN` | No | — | GitHub PAT for private repos |
| `GIT_REPO_SUBDIR` | No | auto-detect | monorepo app subdir (e.g. `example`) |

\*If missing, script should log "polling disabled" and exit 0.

---

## Step 2: Handle Monorepo Path Prefixes

If your app is in a subdirectory (for example `example/`), remote paths may look like:

- `example/lib/...`
- `example/config/...`

but local app files live at:

- `/app/lib/...`
- `/app/config/...`

To avoid accidentally writing `/app/example/...`, map remote paths to local paths:

1. Determine `REMOTE_PATH_PREFIX` from `GIT_REPO_SUBDIR` (or auto-detect).
2. During reconciliation, strip that prefix:
   - remote `example/lib/foo.ex` -> local `lib/foo.ex`
3. Ignore remote paths outside the selected app subtree.

---

## Step 3: Start Polling from `start-wrapper.sh`

In `start-wrapper.sh`:

- define `GIT_POLL_SCRIPT="/app/bin/git-poll.sh"`
- if `GIT_REPO_URL` and `GIT_BRANCH` are set:
  - launch `"$GIT_POLL_SCRIPT" &`
  - store PID
- stop it during cleanup (`TERM`/`INT`) before exiting wrapper

This keeps polling lifecycle tied to wrapper lifecycle.

---

## Step 4: Update Dockerfile

Copy the new script and set execute permissions:

```dockerfile
COPY bin/git-poll.sh /app/bin/git-poll.sh
RUN chmod +x /app/bin/start-wrapper.sh /app/bin/rebuild.sh /app/bin/healthcheck.sh /app/bin/git-poll.sh
```

This is an additive change on top of Pattern 1.

---

## Step 5: Pass Runtime Env Vars

When running the container, pass polling settings:

```sh
-e GIT_REPO_URL=$GIT_REPO_URL \
-e GIT_BRANCH=$GIT_BRANCH \
-e GIT_TOKEN=$GIT_TOKEN \
-e GIT_POLL_INTERVAL=$GIT_POLL_INTERVAL \
-e GIT_REPO_SUBDIR=$GIT_REPO_SUBDIR \
```

For monorepos, set:

```sh
GIT_REPO_SUBDIR=example
```

---

## Operational Notes

- Reconciliation should be lock-protected so only one rebuild runs at a time.
- If fetch fails, retry next poll cycle (do not exit).
- If rebuild fails, keep polling; the next commit should trigger another attempt.
- `mix deps.get` can run every cycle; it is a fast no-op when unchanged.
- Script updates (`bin/git-poll.sh`) written by reconciliation generally apply after container restart (running process keeps current script in memory).

---

## Validation Checklist

After implementation, verify:

1. Container starts normally with polling disabled (no env vars).
2. Polling starts when `GIT_REPO_URL` and `GIT_BRANCH` are present.
3. Pushing a commit updates expected files under `/app` and triggers rebuild.
4. In monorepo mode, no duplicate nested path appears (e.g. `/app/example/...`).
5. Deletions upstream remove local files.
6. Failed rebuild does not kill wrapper; next commit still triggers.

---

## Common Failure Modes

| Symptom | Likely Cause | Fix |
|---|---|---|
| New files appear under `/app/example/...` | repo root != app root | set `GIT_REPO_SUBDIR=example` |
| Polling logs "disabled" | missing env vars | set `GIT_REPO_URL` and `GIT_BRANCH` |
| Private repo fetch fails | token missing/invalid | use PAT with `Contents: read` |
| Rebuilds skipped forever | stale lock file | ensure lock is removed on all error/exit paths |
| No updates during long rebuild | lock active | expected; latest commit picked up next cycle |

---

## Relationship Between Patterns

- Pattern 1 provides process lifecycle safety (wrapper, health checks, rollback, release slots).
- Pattern 2 provides source sync automation (poll + reconcile + rebuild trigger).

Together they form a practical remote iteration system:

`git push -> container self-updates -> wrapper enforces uptime + rollback`.
