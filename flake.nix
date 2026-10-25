{
  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1.*.tar.gz";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    # Fork of okami.mom/albedo carrying the --tailnet-auth patch. Bump the rev,
    # run nix flake lock, and the image workflow rebuilds the app.
    albedo.url = "git+https://tangled.org/karitham.dev/albedo?rev=ceb0f5a39b6879ff6ae039c7962f8a853815384a";
  };
  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
      albedo,
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
      packages = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          albedoPkgs = albedo.packages.${system};
          runtimeTools = with pkgs; [
            bashInteractive
            bzip2
            coreutils
            curl
            findutils
            git
            gnugrep
            gnused
            gzip
            jq
            less
            openssh
            procps
            ripgrep
            tzdata
            which
            xz
          ];
          # The CLI reaches the tailscaled in the sidecar container, whose
          # socket is not the CLI's default.
          tailscale = pkgs.writeShellScriptBin "tailscale" ''
            exec ${pkgs.tailscale}/bin/tailscale --socket "''${TS_SOCKET:-/run/tailscale/tailscaled.sock}" "$@"
          '';
        in
        {
          albedo-image = pkgs.dockerTools.buildLayeredImage {
            name = "albedo";
            tag = "latest";
            contents = [
              albedoPkgs.default
              pkgs.dockerTools.fakeNss
              pkgs.cacert
              tailscale
            ]
            ++ runtimeTools;
            extraCommands = ''
              mkdir -p root run/tailscale tmp usr/bin var/tmp workspace
              # Scripts outside the Nix store look for /usr/bin/env.
              ln -sf /bin/env usr/bin/env
            '';
            config = {
              Env = [
                "HOME=/root"
                "USER=root"
                "LOGNAME=root"
                "PATH=/usr/bin:/bin:${nixpkgs.lib.makeBinPath runtimeTools}"
                "ALBEDO_NO_BROWSER=1"
                "TS_SOCKET=/run/tailscale/tailscaled.sock"
                "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-certificates.crt"
                "GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-certificates.crt"
                "NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-certificates.crt"
                "LANG=C.UTF-8"
                "TZ=UTC"
                "TZDIR=${pkgs.tzdata}/share/zoneinfo"
              ];
              Entrypoint = [ "/bin/albedo" ];
              WorkingDir = "/root";
              ExposedPorts."4317/tcp" = { };
            };
          };
        }
      );

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
