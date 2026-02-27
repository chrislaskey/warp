# Warp

Patterns for rapidly iterating on remote Elixir docker instances.

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
