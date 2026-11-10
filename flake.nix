{
  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1.*.tar.gz";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    # Fork of okami.mom/albedo carrying the --tailnet-auth patch. Bump the rev,
    # run nix flake lock, and the image workflow rebuilds the app.
    albedo.url = "git+https://tangled.org/karitham.dev/albedo?ref=tailnet-machines";
    # The MCP servers and agent skills the image carries come from the dotfiles
    # flake, so a container and a laptop are configured from one place. A
    # dotfiles change reaches the image the next time this input is bumped
    # (`nix flake lock --update-input dotfiles`); a fork revision bump does not
    # carry one.
    dotfiles = {
      url = "github:karitham/dotfiles";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
      albedo,
      dotfiles,
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
              # /etc/albedo holds the extensions.json and skills the dotfiles
              # declare, and /bin/albedo-seed installs them into the home
              # volume; the deployment runs it before the daemon starts.
              dotfiles.packages.${system}.albedo-config
              dotfiles.packages.${system}.albedo-seed
            ]
            ++ runtimeTools;
            extraCommands = ''
              mkdir -p root run/tailscale tmp usr/bin var/tmp workspace
              # Scripts outside the Nix store look for /usr/bin/env.
              ln -sf /bin/env usr/bin/env
              # Erlang reads the OS trust store, not SSL_CERT_FILE.
              mkdir -p etc/ssl/certs
              ln -sf ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt etc/ssl/certs/ca-certificates.crt
            '';
            config = {
              Env = [
                "HOME=/root"
                "USER=root"
                "LOGNAME=root"
                "PATH=/usr/bin:/bin:${nixpkgs.lib.makeBinPath runtimeTools}"
                "ALBEDO_NO_BROWSER=1"
                "TS_SOCKET=/run/tailscale/tailscaled.sock"
                "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
                "GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
                "NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
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
