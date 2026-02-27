#!/bin/bash

docker build -f Dockerfile -t warp-example .

docker run --rm \
  --name warp-example \
  -e SECRET_KEY_BASE=$(openssl rand -base64 48) \
  -e DATABASE_PATH=/tmp/test.db \
  -e PHX_HOST=localhost \
  -e PHX_SCHEME=http \
  -e PORT=4000 \
  -e GIT_REPO_URL=$GIT_REPO_URL \
  -e GIT_BRANCH=$GIT_BRANCH \
  -e GIT_TOKEN=$GIT_TOKEN \
  -e GIT_POLL_INTERVAL=$GIT_POLL_INTERVAL \
  -p 4000:4000 \
  warp-example
