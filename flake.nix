{
  inputs.nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1.*.tar.gz";
  outputs = {
    self,
    nixpkgs,
  }: let
    supportedSystems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    forEachSupportedSystem = f:
      nixpkgs.lib.genAttrs supportedSystems (system:
        f {
          pkgs = import nixpkgs {inherit system;};
        });
  in {
    devShells = forEachSupportedSystem ({pkgs}: {
      default = pkgs.mkShell {
              packages = let
                alloy = pkgs.stdenv.mkDerivation {
                  name = "alloy";
                  version = "1.3.1";
                  src = pkgs.fetchzip {
                    url = "https://github.com/grafana/alloy/releases/download/v1.3.1/alloy-linux-amd64.zip";
                    sha256 = "sha256-v6/1Qt9qZGhwhP6qtEvXmvS+y0QLW1Mvnouql+HO6C0="; # Replace with actual hash
                  };
                  installPhase = ''
                    mkdir -p $out/bin
                    cp alloy-linux-amd64 $out/bin/alloy
                    chmod +x $out/bin/alloy
                  '';
                };
              in with pkgs; [
          kubectx
          kubectl
          kubernetes-helm
          kubernetes-helmPlugins.helm-diff
          helmfile
          sops
          fluxcd
          age
          alloy
        ];
      };
    });
  };
}
