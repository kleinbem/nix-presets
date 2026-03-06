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
    openclaw = {
      url = "github:openclaw/nix-openclaw";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-devshells.url = "path:../nix-devshells";
    nix-devshells.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs@{ flake-parts, self, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];
      imports = [ ];

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
              (_final: prev: {
                stable = prev;
              })
            ];
          };
        in
        {
          formatter = inputs.nix-devshells.formatter.${system};

          checks.pre-commit-check = inputs.pre-commit-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              nixfmt.enable = true;
              statix.enable = true;
              deadnix.enable = true;
            };
          };

          devShells.default = pkgs.mkShell {
            shellHook = ''
              ${config.checks.pre-commit-check.shellHook}
              echo "🧩 Presets Flake DevEnv"
            '';
            buildInputs = [
              pkgs.nixfmt
              pkgs.statix
              pkgs.deadnix
            ];
          };

          packages =
            (import ./pkgs/nixpak/default.nix {
              pkgs = appsPkgs;
              inherit (inputs) nixpak;
            })
            // (import ./pkgs/waydroid/default.nix {
              inherit pkgs;
            })
            // (import ./pkgs/redroid/default.nix {
              inherit pkgs inputs;
            });
        };

      flake = {
        lib = {
          mkContainer = import ./lib/factory.nix { inherit (inputs.nixpkgs) lib; };
        };

        nixosModules = {
          # Generic Modules
          container-common = import ./containers/common.nix;
          n8n = import ./containers/n8n.nix { inherit self; };
          silverbullet = import ./containers/silverbullet.nix { inherit self; };
          code-server = import ./containers/code-server.nix { inherit self; };
          open-webui = import ./containers/open-webui.nix { inherit self; };
          dashboard = import ./containers/dashboard { inherit self; };
          dashboard-custom = import ./containers/dashboard { inherit self; };
          dashboard-homer = import ./containers/dashboard/homer { inherit self; };
          dashboard-homepage = import ./containers/dashboard/homepage { inherit self; };
          ollama = import ./containers/ollama.nix { inherit self; };
          qdrant = import ./containers/qdrant.nix { inherit self; };
          playground = import ./containers/playground.nix { inherit self; };
          caddy = import ./containers/caddy { inherit self; };
          comfyui = import ./containers/comfyui.nix { inherit self; };
          langfuse = import ./containers/langfuse.nix { inherit self; };
          langflow = import ./containers/langflow.nix { inherit self; };
          vllm = import ./containers/vllm.nix { inherit self; };
          openclaw = import ./containers/openclaw.nix { inherit self inputs; };
          agent-zero = import ./containers/agent-zero.nix { inherit self; };
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
