#!/bin/sh
set -eu

# Liveness check for the loopback-bound server: a plain TCP probe dialed from
# the kubelet cannot reach 127.0.0.1, so answer an authenticated HTTP request
# from inside the container instead.
AUTH="$(printf 'opencode:%s' "$OPENCODE_SERVER_PASSWORD" | base64 | tr -d '\n')"
wget -q -T 10 -O /dev/null --header "Authorization: Basic $AUTH" http://127.0.0.1:4097/api/info
