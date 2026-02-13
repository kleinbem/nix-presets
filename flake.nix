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
    nix-waydroid-setup.url = "path:/home/martin/Develop/github.com/kleinbem/nix/nix-waydroid-setup";
    nix-waydroid-setup.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs@{ flake-parts, ... }:
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

          packages = import ./pkgs/nixpak/default.nix {
            pkgs = appsPkgs;
            nixpak = inputs.nixpak;
          };
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
          waydroid = import ./waydroid.nix { inherit inputs; };
        };
        homeManagerModules = {
          opencode = import ./opencode.nix;
          terminal = import ./terminal.nix;
          desktop = import ./desktop.nix;
        };
      };
    };
}
