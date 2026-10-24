#!/bin/sh
set -eu

# https://tangled.org/karitham.dev/albedo/commit/3dac947eb3e30677f312627d55506b1b147392f4
ALBEDO_REV=3dac947eb3e30677f312627d55506b1b147392f4
ALBEDO_SHA256=9e84ca874f4734d4cbf36f61f3a432459e42e63c2ce0f984395f419cd3d918a6
ARCHIVE=/tmp/albedo-source.tar.gz
SOURCE=/tmp/albedo-source

mkdir -p /root/.config/nix "$SOURCE"
cat > /root/.config/nix/nix.conf <<'EOF'
experimental-features = nix-command flakes
sandbox = true
build-users-group = nixbld
EOF

curl -fsSL "https://tangled.org/karitham.dev/albedo/archive/$ALBEDO_REV.tar.gz" -o "$ARCHIVE"
echo "$ALBEDO_SHA256  $ARCHIVE" | sha256sum -c -
tar -xzf "$ARCHIVE" --strip-components=1 -C "$SOURCE"

# package.nix fetches the locked inputs directly. Albedo's usage-core URL has
# query parameters that Nix mistakes for flake input attributes.
nix build --impure --expr 'import /etc/albedo/package.nix' --out-link /root/.nix-profile-albedo
