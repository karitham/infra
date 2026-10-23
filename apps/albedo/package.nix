let
  nixpkgs = builtins.fetchTree {
    type = "github";
    owner = "NixOS";
    repo = "nixpkgs";
    rev = "e7439b6b14ad3cc35d05608ebca9bce01a25f5f8";
    narHash = "sha256-H83yz/do+hjOO0uujHyH8RgtIQP2v7Mw+cLwcZK/xKc=";
  };
  pkgs = import nixpkgs { };
  albedoSource = /tmp/albedo-source;
  usage-core = builtins.fetchTree {
    type = "file";
    url = "https://api.next.tangled.org/xrpc/org.tangled.temp.git.getArchive?repo=did%3Aplc%3A2lf7buutfnfcucljnmaypf7u&ref=3951be3&format=tar.gz&prefix=provide-usage-main";
    narHash = "sha256-dKjqffpCenUg0nKEiAepCfRsQxRk5odins7AR+1CA0c=";
  };
  chrome-headless-shell = pkgs.callPackage (albedoSource + "/flake/chrome-headless-shell.nix") { };
  albedo = pkgs.callPackage (albedoSource + "/default.nix") {
    inherit usage-core chrome-headless-shell;
  };
  tailscale = pkgs.writeShellScriptBin "tailscale" ''
    exec ${pkgs.tailscale}/bin/tailscale --socket "''${TS_SOCKET:-/var/run/tailscale/tailscaled.sock}" "$@"
  '';
in
pkgs.symlinkJoin {
  name = "albedo-runtime";
  paths = [
    albedo
    pkgs.git
    tailscale
  ];
}
