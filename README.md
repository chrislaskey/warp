# Warp

Patterns for rapidly iterating on remote Elixir docker instances.

## Implementation guides

- `implementation-guides/warp-dockerfile-pattern.md`
- `implementation-guides/warp-github-poll-pattern.md`

## Pattern 1

### Reusable build environment

The first step in this pattern is to use a single-stage Docker build instead of
a multi-stage.

The downside of this approach is it increases the size of the
final docker image.

The upside is it ensures all the build tools are still available to create a new relase.

### Multiple releases

When building a release, keep the old version around instead of replacing it.

Note: releases on large applications can take up meaningful disk space, so it only
keeps the last few builds.

### Updatable releases binaries

The next step is to make it possible to use a different release without having
to rebuild the Docker container.

By default, the Docker container points to the release binary. This means if
the current release is stopped, the Docker container exits. Which becomes
problematic when trying to deploy a new release in place of the old one.

The fix is to make the Docker entrypoint a thin wrapper that calls the release
as a child process. This way the child process can be changed without the
Docker container exiting.

### Basic rollback detection

If the wrapper script detects failures in the new release, it can be updated to
rollback to he previous release.

## Pattern 2

### GitHub pull

The second pattern layers on top of Pattern 1 by adding a background polling
process inside the container.

The process watches a branch in GitHub, detects new commits, reconciles changed
files in `/app`, and runs the rebuild script.

This gives a simple flow:

- edit code locally
- push to GitHub
- container detects commit
- container rebuilds and restarts

### File-level reconciliation

Recompilation of Elixir projects inside Docker containers can be tricky to get right. Sometimes there are longer recompilation loops. Sometimes, it fails.

To try to reduce that risk, instead of `git rebase` or `git reset` in the running container, this pattern tracks changed paths and updates only those paths to the latest commit state.

That keeps the update path explicit and avoids full tree rewrite behavior that
can lead to unstable compile behavior in iterative container workflows.

### Monorepo path mapping

When the app is in a subdirectory (for example `example/`), paths from GitHub
must be mapped to `/app`.

Set `GIT_REPO_SUBDIR` so a remote path like `example/lib/...` is written to
`/app/lib/...` instead of `/app/example/lib/...`.
