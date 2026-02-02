{
  description = "Shared Modules & Presets";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
    pre-commit-hooks.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      perSystem = { config, pkgs, system, ... }: {
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
      };

      flake = {
        nixosModules = {
          # Add modules here
          # example = import ./modules/example.nix;
        };
        homeManagerModules = {
           opencode = import ./opencode.nix;
        };
      };
    };
}
