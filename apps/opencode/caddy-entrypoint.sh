#!/bin/sh
set -eu

# Derive the Basic header from the server password so the credential exists
# in one place.
OPENCODE_AUTH="$(printf 'opencode:%s' "$OPENCODE_SERVER_PASSWORD" | base64 | tr -d '\n')"
export OPENCODE_AUTH

exec caddy run --config /etc/opencode/Caddyfile --adapter caddyfile
