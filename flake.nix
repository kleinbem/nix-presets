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
    hermes = {
      # Held at the last rev that builds on our nixpkgs: from df722c88 on,
      # hermes ships node 26.12.1 prebuilt, and patchelf 0.19.2 leaves it with
      # overlapping LOAD segments, so it segfaults on start (hermes-tui/web).
      # upstream: NixOS/patchelf#672 (0.19.3), NixOS/nixpkgs#582116.
      # Drop once nixpkgs has patchelf >= 0.19.3.
      url = "github:NousResearch/hermes-agent/81a55437f3f31a9f12a30c53b6c5d49d420898aa";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-devshells = {
      url = "github:kleinbem/nix-devshells";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-packages.url = "github:kleinbem/nix-packages";
    nix-packages.inputs.nixpkgs.follows = "nixpkgs";
    # bubblewrap sandboxes for desktop apps (pkgs/nixpak/, desktop.nix)
    nixpak.url = "github:nixpak/nixpak";
    nixpak.inputs.nixpkgs.follows = "nixpkgs";
    nix-gantry.url = "github:kleinbem-dev/nix-gantry";
    # Packages the fleet holds back from nixos-unstable; mkContainer gives
    # them to every container.
    nix-detour-fleet = {
      url = "github:kleinbem/nix-detour-fleet";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nix-packages.follows = "nix-packages";
    };
    nix-gantry.inputs.nixpkgs.follows = "nixpkgs";
    revue = {
      url = "github:kleinbem-dev/revue";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    foyer = {
      url = "github:kleinbem-dev/foyer";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    attic-ui = {
      url = "github:kleinbem-dev/attic-ui";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
            config.allowUnfree = true;
          };
          pkgsWithExts = pkgsUnfree.extend inputs.nix-vscode-extensions.overlays.default;
          bundles = import ./code-common/bundles.nix { pkgs = pkgsWithExts; };
          sandboxedApps = import ./nixpak/apps.nix {
            pkgs = pkgsUnfree; # discord
            inherit (inputs) nixpak;
          };
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
                          nixpkgs.config.allowUnfree = true;
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

              # The nixpkgs NixOS tests of the held packages (kleinbem/nix-detour-fleet),
              # with the holds and our fixes for them, as in the containers.
              heldPkgs = import inputs.nixpkgs {
                inherit system;
                config.allowUnfree = true;
                overlays = [
                  inputs.nix-detour-fleet.overlays.default
                  self.overlays.open-webui
                ];
              };
              heldTests = inputs.nixpkgs.lib.mapAttrs' (
                name: test: inputs.nixpkgs.lib.nameValuePair "held-${name}" test
              ) (inputs.nix-detour-fleet.lib.nixosTests heldPkgs);

              moduleChecks = inputs.nixpkgs.lib.mapAttrs' (
                name: module: inputs.nixpkgs.lib.nameValuePair "module-${name}" (mkModuleCheck module)
              ) (inputs.nixpkgs.lib.filterAttrs (n: _: !(builtins.elem n excludedModules)) self.nixosModules);
            in
            {
              backup-engine = import ./checks/backup-engine.nix {
                inherit pkgs;
                module = ./nixosModules/backup-engine;
              };

              forgejo = import ./checks/forgejo.nix {
                inherit pkgs;
                module = self.nixosModules.forgejo;
              };

              ente = import ./checks/ente.nix {
                inherit pkgs;
                module = self.nixosModules.ente;
              };

              # Built here so a broken bump fails CI, not only the updater.
              inherit (config.packages) freecad-mcp;

              pre-commit-check = inputs.git-hooks.lib.${system}.run {
                src = ./.;
                hooks = {
                  nixfmt.enable = true;
                  statix.enable = true;
                  deadnix.enable = true;
                };
              };
            }
            // heldTests
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
            # Standalone build target for the sandbox desktop.nix installs.
            element-desktop-sandboxed = sandboxedApps.element-desktop;
            signal-desktop-sandboxed = sandboxedApps.signal-desktop;
            discord-sandboxed = sandboxedApps.discord;
            # The FreeCAD MCP server mcp.nix installs.
            freecad-mcp = pkgs.python3.pkgs.callPackage ./pkgs/freecad-mcp.nix { };
          };
        };

      flake = {
        # Fixes for packages the containers use, shared with the checks that
        # test them.
        overlays.open-webui = import ./overlays/open-webui.nix;

        lib = {
          # nix-gantry's mkContainer, defaulting cfg.hostBridge and
          # cfg.gpuRenderNode from the fleet's my.* options. Containers don't get
          # host overlays, so this also adds the held packages
          # (nix-detour-fleet) ahead of the container's own overlays.
          mkContainer =
            args:
            let
              innerConfig = args.innerConfig or { };
            in
            inputs.nix-gantry.lib.mkContainer (
              args
              // {
                cfg = args.cfg // {
                  hostBridge = args.cfg.hostBridge or args.config.my.network.bridge;
                  gpuRenderNode = args.cfg.gpuRenderNode or args.config.my.hardware.gpuRenderNode;
                };
                innerConfig = innerArgs: {
                  imports = [
                    (if builtins.isFunction innerConfig then innerConfig innerArgs else innerConfig)
                  ];
                  nixpkgs = {
                    config = {
                      allowUnfree = true;
                      allowUnfreePredicate = _: true;
                      # no-link: nixpkgs marks openclaw insecure by design (prompt injection), not a
                      # bug awaiting a fix; host-side egress containment lives in containers/openclaw.nix.
                      allowInsecurePredicate = pkg: builtins.elem (inputs.nixpkgs.lib.getName pkg) [ "openclaw" ];
                    };
                    overlays = inputs.nixpkgs.lib.mkBefore [ inputs.nix-detour-fleet.overlays.default ];
                  };
                };
              }
            );
        };

        nixosModules =
          let
            presets = {
              # Generic Modules
              attic-push = ./attic-push.nix;
              herdr-remote-client = ./herdr-remote-client.nix;
              container-common = import ./containers/common.nix;
              github-runner = import ./containers/github-runner.nix { inherit self; };
              cups = import ./containers/cups.nix { inherit self; };
              ollama = import ./containers/ollama.nix { inherit self; };
              llama-cpp = import ./containers/llama-cpp.nix { inherit self; };
              n8n = import ./containers/n8n.nix { inherit self; };
              caddy = import ./containers/caddy { inherit self inputs; };
              attic = import ./containers/attic.nix { inherit self; };
              code-server = import ./containers/code-server.nix { inherit self; };
              open-webui = import ./containers/open-webui.nix { inherit self; };
              dashboard-homer = import ./containers/dashboard/homer { inherit self; };
              dashboard-foyer = import ./containers/dashboard/foyer { inherit self inputs; };
              qdrant = import ./containers/qdrant.nix { inherit self; };
              ntfy = import ./containers/ntfy.nix { inherit self; };
              stalwart = import ./containers/stalwart.nix { inherit self; };
              authentik = import ./containers/authentik.nix { inherit self; };
              nextcloud = import ./containers/nextcloud.nix { inherit self; };
              playground = import ./containers/playground.nix { inherit self; };
              frigate = import ./containers/frigate.nix { inherit self; };
              comfyui = import ./containers/comfyui.nix { inherit self; };
              langfuse = import ./containers/langfuse.nix { inherit self inputs; };
              langflow = import ./containers/langflow.nix { inherit self; };
              openclaw = import ./containers/openclaw.nix { inherit self inputs; };
              hermes = import ./containers/hermes.nix { inherit self inputs; };
              persona-runtime = import ./containers/persona-runtime.nix { inherit self inputs; };
              buzz = import ./containers/buzz.nix { inherit self; };
              monitoring = import ./containers/monitoring.nix { inherit self; };
              monitoring-node = import ./nixosModules/monitoring-node.nix;
              agent-zero = import ./containers/agent-zero.nix { inherit self; };
              agent-team = import ./containers/agent-team.nix { inherit self; };
              litellm = import ./containers/litellm.nix { inherit self; };
              loki = import ./containers/loki.nix { inherit self; };
              crowdsec = import ./containers/crowdsec.nix { inherit self; };
              netdata = import ./containers/netdata.nix { inherit self; };
              claude = import ./nixosModules/claude.nix;
              bottles = import ./nixosModules/bottles.nix;
              photo-frame = ./nixosModules/photo-frame;
              sandboxed-apps = import ./nixosModules/sandboxed-apps.nix { inherit inputs; };

              home-assistant = import ./containers/home-assistant.nix { inherit self; };
              music-assistant = import ./containers/music-assistant.nix { inherit self; };
              syncthing = import ./containers/syncthing.nix { inherit self; };
              backup = import ./containers/backup.nix { inherit self; };
              # Host-level backup engine + `my.backup` interface (supersedes the
              # `backup` container above; presets register their own data).
              # A path (not `import`), so it dedups with the presets' own
              # `imports = [ ../nixosModules/backup-engine ]`.
              backup-engine = ./nixosModules/backup-engine;
              paperless = import ./containers/paperless.nix { inherit self; };
              anythingllm = import ./containers/anythingllm.nix { inherit self; };
              ente = import ./containers/ente.nix { inherit self inputs; };
              vaultwarden = import ./containers/vaultwarden.nix { inherit self; };
              gatus = import ./containers/gatus.nix { inherit self; };
              dev-db = import ./containers/dev-db.nix { inherit self; };
              qbittorrent = import ./containers/qbittorrent.nix { inherit self; };
              caido = import ./containers/caido.nix { inherit self; };
              garage-ui = import ./containers/garage-ui.nix { inherit self; };
              miniflux = import ./containers/miniflux.nix { inherit self; };
              forgejo = import ./containers/forgejo.nix { inherit self; };
              revue = import ./containers/revue.nix { inherit self inputs; };
            };

            # `all` leaves out dashboard-homer: it declares the same
            # my.containers.dashboard options as dashboard-foyer. A host that
            # wants it imports the modules it needs plus dashboard-homer, not `all`.
            variants = [
              "dashboard-homer"
            ];
          in
          presets
          // {
            # Every preset (all default to enable = false). For hosts where eval
            # cost doesn't matter; devices that eval their own config should
            # import presets selectively.
            all.imports = builtins.attrValues (builtins.removeAttrs presets variants);
          };
        homeManagerModules = {
          opencode = import ./opencode.nix;
          terminal = import ./terminal.nix;
          vcs = import ./vcs.nix;
          desktop = import ./desktop.nix;
          dx = import ./dx.nix;
          herdr = import ./herdr.nix;
          mcp = import ./mcp.nix;
        };
      };
    };
}
