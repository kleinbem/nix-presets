{
  description = "Shared Modules & Presets";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
    pre-commit-hooks.inputs.nixpkgs.follows = "nixpkgs";
    nixpak.url = "github:nixpak/nixpak";
    nixpak.inputs.nixpkgs.follows = "nixpkgs";
    # Redroid GApps
    gapps-arm64 = {
      url = "https://github.com/MindTheGapps/16.0.0-arm64/releases/download/MindTheGapps-16.0.0-arm64-20250812_214353/MindTheGapps-16.0.0-arm64-20250812_214353.zip";
      flake = false;
    };
    gapps-amd64 = {
      url = "path:./pkgs/redroid/placeholder.zip";
      flake = false;
    };
  };

  outputs =
    inputs@{ flake-parts, self, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];
      imports = [
        inputs.treefmt-nix.flakeModule
      ];

      perSystem =
        {
          config,
          pkgs,
          system,
          ...
        }:
        let
          # Custom pkgs for standalone app building (needs unfree + stable alias)
          appsPkgs = import inputs.nixpkgs {
            inherit system;
            config.allowUnfree = true;
            overlays = [
              (final: prev: {
                stable = prev;
              })
            ];
          };
        in
        {
          treefmt = {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
          };

          checks.pre-commit-check = inputs.pre-commit-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              nixfmt.enable = true;
            };
          };

          devShells.default = pkgs.mkShell {
            shellHook = ''
              ${config.checks.pre-commit-check.shellHook}
              echo "🧩 Presets Flake DevEnv"
            '';
            buildInputs = [
              pkgs.nixfmt
            ];
          };

          packages =
            (import ./pkgs/nixpak/default.nix {
              pkgs = appsPkgs;
              nixpak = inputs.nixpak;
            })
            // (import ./pkgs/waydroid/default.nix {
              inherit pkgs;
            })
            // (import ./pkgs/redroid/default.nix {
              inherit pkgs inputs;
            });
        };

      flake = {
        nixosModules = {
          # Generic Modules
          n8n = import ./containers/n8n.nix;
          silverbullet = import ./containers/silverbullet.nix;
          code-server = import ./containers/code-server.nix;
          open-webui = import ./containers/open-webui.nix;
          dashboard = import ./containers/dashboard.nix;
          ollama = import ./containers/ollama.nix;
          qdrant = import ./containers/qdrant.nix;
          waydroid = import ./nixosModules/waydroid.nix { inherit self; };
          android-emulator = import ./nixosModules/android-emulator.nix;
        };
        homeManagerModules = {
          opencode = import ./opencode.nix;
          terminal = import ./terminal.nix;
          desktop = import ./desktop.nix;
        };
      };
    };
}
