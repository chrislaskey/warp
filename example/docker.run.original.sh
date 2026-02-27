#!/bin/bash

docker build -f Dockerfile.original -t warp-example-original .

docker run --rm \
  --name warp-example-original \
  -e SECRET_KEY_BASE=$(openssl rand -base64 48) \
  -e DATABASE_PATH=/tmp/test.db \
  -e PHX_HOST=localhost \
  -p 8080:8080 \
  warp-example-original
