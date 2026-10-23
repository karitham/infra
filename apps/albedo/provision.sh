#!/bin/sh
set -eu

ALBEDO_REV=561f4eb5e3a78445f3af4524d579d5f839e99cf0
ALBEDO_SHA256=4c3bafde94def89f578d237ad534997fe671f830de377c9e471d7c5075d5cf21
ARCHIVE=/tmp/albedo-source.tar.gz
SOURCE=/tmp/albedo-source

mkdir -p /root/.config/nix "$SOURCE"
cat > /root/.config/nix/nix.conf <<'EOF'
experimental-features = nix-command flakes
sandbox = true
build-users-group = nixbld
EOF

curl -fsSL "https://tangled.org/okami.mom/albedo/archive/$ALBEDO_REV.tar.gz" -o "$ARCHIVE"
echo "$ALBEDO_SHA256  $ARCHIVE" | sha256sum -c -
tar -xzf "$ARCHIVE" --strip-components=1 -C "$SOURCE"

# package.nix fetches the locked inputs directly. Albedo's usage-core URL has
# query parameters that Nix mistakes for flake input attributes.
nix build --impure --expr 'import /etc/albedo/package.nix' --out-link /root/.nix-profile-albedo
