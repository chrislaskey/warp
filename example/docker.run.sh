#!/bin/bash

docker build -f Dockerfile -t warp-example .

docker run --rm \
  --name warp-example \
  -e SECRET_KEY_BASE=$(openssl rand -base64 48) \
  -e DATABASE_PATH=/tmp/test.db \
  -e PHX_HOST=localhost \
  -e PHX_SCHEME=http \
  -e PORT=4000 \
  -p 4000:4000 \
  warp-example
