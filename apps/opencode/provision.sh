#!/bin/sh
set -eu

# Write the Nix config to the home PVC, not /etc/nix. This script runs as an
# initContainer, and initContainers have a root filesystem separate from the
# app container; only the declared volumeMounts are shared. A config written to
# /etc is discarded when this container exits, so the app container falls back
# to built-in defaults (sandbox = true, nix-command disabled) and every
# derivation build fails. $XDG_CONFIG_HOME/nix/nix.conf is read by Nix, and
# /root is the opencode-home PVC mounted into both containers.
mkdir -p /root/.config/nix
cat > /root/.config/nix/nix.conf <<'EOF'
experimental-features = nix-command flakes
sandbox = false
build-users-group =
EOF

# Install Nix once onto the persistent /nix volume. coreutils is required
# because the installer uses GNU cp options that BusyBox cp does not support.
# These apk packages land in this initContainer's own layer and are intentionally
# not expected in the app container; only /root and /nix carry across.
if ! command -v nix >/dev/null 2>&1; then
  echo "installing nix into /nix (persistent)..."
  apk add --no-cache bash coreutils curl xz >/dev/null
  mkdir -p /nix
  curl -fsSL https://releases.nixos.org/nix/nix-2.35.2/install -o /tmp/nix-install.sh
  sh /tmp/nix-install.sh --no-daemon
  rm -f /tmp/nix-install.sh
fi

# git comes from the persistent nix profile, pinned to the nixpkgs revision in
# this repo's flake.lock so the toolchain changes only when that is bumped.
if ! command -v git >/dev/null 2>&1; then
  echo "installing git via nix (persistent)..."
  nix profile install github:NixOS/nixpkgs/4533d9293756b63904b7238acb84ac8fe4c8c2c4#git
fi
