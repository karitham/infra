{
  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1.*.tar.gz";
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };
  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forEachSupportedSystem =
        f: nixpkgs.lib.genAttrs supportedSystems (system: f { pkgs = import nixpkgs { inherit system; }; });
    in
    {
      formatter = forEachSupportedSystem (
        { pkgs }:
        treefmt-nix.lib.mkWrapper pkgs {
          projectRootFile = "flake.nix";
          programs.nixfmt.enable = true;
          programs.yamlfmt.enable = true;
          programs.prettier.enable = true;
          programs.prettier.settings = { };
          settings.formatter.alloy = {
            command = nixpkgs.lib.getExe' pkgs.grafana-alloy "alloy";
            options = [
              "fmt"
              "-w"
            ];
            includes = [ "*.alloy" ];
            # alloy fmt accepts at most one file per invocation.
            no-positional-arg-support = true;
          };
          settings.global.excludes = [
            "*.sops.yaml"
            "*secret.yaml"
            "apps/waifubot/pg.yaml"
            "clusters/riko/core/cert-manager/issuers/secret.yaml"
            "clusters/riko/flux-system/gotk-components.yaml"
            "data-alloy/**"
            "result*"
            ".jj/**"
            ".direnv/**"
          ];
        }
      );

      devShells = forEachSupportedSystem (
        { pkgs }: {
          default = pkgs.mkShell {
            packages = [
              pkgs.kubectx
              pkgs.kubectl
              pkgs.sops
              pkgs.fluxcd
              pkgs.age
              pkgs.grafana-alloy
              pkgs.pre-commit
              pkgs.gitleaks
              pkgs.jq
            ];
          };
        }
      );
    };
}
