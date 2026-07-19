{
  description = "Shared Modules & Presets";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    nix-vscode-extensions = {
      url = "github:nix-community/nix-vscode-extensions";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";

    openclaw = {
      url = "github:openclaw/nix-openclaw";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-devshells = {
      url = "github:kleinbem/nix-devshells";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-packages.url = "github:kleinbem/nix-packages";
    nix-packages.inputs.nixpkgs.follows = "nixpkgs";
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
          pkgsUnfree = import inputs.nixpkgs {
            inherit system;
            config = {
              allowUnfree = true;
              android_sdk.accept_license = true;
            };
          };
          pkgsWithExts = pkgsUnfree.extend inputs.nix-vscode-extensions.overlays.default;
          bundles = import ./code-common/bundles.nix { pkgs = pkgsWithExts; };
        in
        # Custom pkgs for standalone app building (needs unfree + stable alias)
        {
          formatter = inputs.nix-devshells.formatter.${system};

          # ---------------------------------------------------------
          # Checks & Verifications
          # ---------------------------------------------------------
          checks =
            let
              # Helper to create a minimal check for a NixOS module
              mkModuleCheck =
                module:
                (inputs.nixpkgs.lib.nixosSystem {
                  inherit system;
                  modules = [
                    module
                    # Provide minimal requirements for the container factory
                    (
                      { lib, ... }:
                      {
                        options.my = {
                          network.bridge = lib.mkOption {
                            type = lib.types.str;
                            default = "br0";
                          };
                          hardware.gpuRenderNode = lib.mkOption {
                            type = lib.types.str;
                            default = "/dev/dri/renderD128";
                          };
                          username = lib.mkOption {
                            type = lib.types.str;
                            default = "test";
                          };
                        };
                        options.sops = {
                          templates = lib.mkOption {
                            type = lib.types.attrsOf lib.types.attrs;
                            default = { };
                          };
                          secrets = lib.mkOption {
                            type = lib.types.attrsOf lib.types.attrs;
                            default = { };
                          };
                        };
                        config = {
                          boot.isContainer = true;
                          system.stateVersion = "25.11";
                          nixpkgs.config = {
                            allowUnfree = true;
                            android_sdk.accept_license = true;

                          };
                          # Mock sops if used
                          sops.templates = lib.mkOptionDefault { };
                          sops.secrets = lib.mkOptionDefault { };
                        };
                      }
                    )
                  ];
                }).config.system.build.toplevel;

              # Exclude modules that require complex external inputs or specific setups
              # for basic evaluation testing.
              excludedModules = [
                "container-common" # Basic helper, not a full module
                "monitoring-node" # Requires more host-level setup
                "all" # Composite of the above; members are checked individually
              ];

              moduleChecks = inputs.nixpkgs.lib.mapAttrs' (
                name: module: inputs.nixpkgs.lib.nameValuePair "module-${name}" (mkModuleCheck module)
              ) (inputs.nixpkgs.lib.filterAttrs (n: _: !(builtins.elem n excludedModules)) self.nixosModules);
            in
            {
              pre-commit-check = inputs.git-hooks.lib.${system}.run {
                src = ./.;
                hooks = {
                  nixfmt.enable = true;
                  statix.enable = true;
                  deadnix.enable = true;
                };
              };
            }
            // moduleChecks;

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

          packages = {
            antigravity-extensions-bundle = bundles.antigravity;
            cursor-extensions-bundle = bundles.cursor;
            windsurf-extensions-bundle = bundles.windsurf;
          };
        };

      flake = {
        lib = {
          mkContainer = import ./lib/factory.nix { inherit (inputs.nixpkgs) lib; };
        };

        nixosModules =
          let
            presets = {
              # Generic Modules
              container-common = import ./containers/common.nix;
              github-runner = import ./containers/github-runner.nix { inherit self; };
              cups = import ./containers/cups.nix { inherit self; };
              ollama = import ./containers/ollama.nix { inherit self; };
              llama-cpp = import ./containers/llama-cpp.nix { inherit self; };
              n8n = import ./containers/n8n.nix { inherit self; };
              caddy = import ./containers/caddy { inherit self; };
              attic = import ./containers/attic.nix { inherit self; };
              code-server = import ./containers/code-server.nix { inherit self; };
              open-webui = import ./containers/open-webui.nix { inherit self; };
              dashboard = import ./containers/dashboard { inherit self; };
              dashboard-custom = import ./containers/dashboard { inherit self; };
              dashboard-homer = import ./containers/dashboard/homer { inherit self; };
              dashboard-homepage = import ./containers/dashboard/homepage { inherit self; };
              qdrant = import ./containers/qdrant.nix { inherit self; };
              ntfy = import ./containers/ntfy.nix { inherit self; };
              stalwart = import ./containers/stalwart.nix { inherit self; };
              authentik = import ./containers/authentik.nix { inherit self; };
              odoo = import ./containers/odoo.nix { inherit self; };
              nextcloud = import ./containers/nextcloud.nix { inherit self; };
              playground = import ./containers/playground.nix { inherit self; };
              frigate = import ./containers/frigate.nix { inherit self; };
              comfyui = import ./containers/comfyui.nix { inherit self; };
              langfuse = import ./containers/langfuse.nix { inherit self inputs; };
              langflow = import ./containers/langflow.nix { inherit self; };
              vllm = import ./containers/vllm.nix { inherit self; };
              openclaw = import ./containers/openclaw.nix { inherit self inputs; };
              monitoring = import ./containers/monitoring.nix { inherit self; };
              monitoring-node = import ./nixosModules/monitoring-node.nix;
              agent-zero = import ./containers/agent-zero.nix { inherit self; };
              agent-team = import ./containers/agent-team.nix { inherit self; };
              litellm = import ./containers/litellm.nix { inherit self; };
              loki = import ./containers/loki.nix { inherit self; };
              crowdsec = import ./containers/crowdsec.nix { inherit self; };
              netdata = import ./containers/netdata.nix { inherit self; };
              authelia = import ./containers/authelia.nix { inherit self; };
              android-emulator = import ./nixosModules/android-emulator.nix;
              claude = import ./nixosModules/claude.nix;

              home-assistant = import ./containers/home-assistant.nix { inherit self; };
              syncthing = import ./containers/syncthing.nix { inherit self; };
              backup = import ./containers/backup.nix { inherit self; };
              paperless = import ./containers/paperless.nix { inherit self; };
              anythingllm = import ./containers/anythingllm.nix { inherit self; };
              ente = import ./containers/ente.nix { inherit self; };
            };

            # Variant implementations of the same preset (they redeclare the
            # options their sibling `dashboard` declares) — importing them
            # alongside it would collide, so the `all` bundle skips them.
            variants = [
              "dashboard-custom"
              "dashboard-homer"
              "dashboard-homepage"
            ];
          in
          presets
          // {
            # Whole-catalogue bundle. Pure Switchboard: every preset defaults
            # to enable = false, so importing everything only declares options.
            # Meant for hosts where eval cost is irrelevant (workstation);
            # edge devices that eval their own config (autoUpgrade) should
            # keep importing presets selectively.
            all.imports = builtins.attrValues (builtins.removeAttrs presets variants);
          };
        homeManagerModules = {
          opencode = import ./opencode.nix;
          terminal = import ./terminal.nix;
          git = import ./git.nix;
          desktop = import ./desktop.nix;
          dx = import ./dx.nix;
          firefox-browser =
            { ... }:
            {
              imports = [ ./firefox.nix ];
              _module.args.inputs = inputs;
            };
          mcp = import ./mcp.nix;
        };
      };
    };
}
