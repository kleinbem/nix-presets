{ self, inputs }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.persona-runtime;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  # Generic, persona-agnostic worker container — ONE declared instance,
  # identity swapped at invocation time instead of one container per
  # persona (hermes-juan.nix's shape). Built 2026-08-08 once "up to ~200
  # personas, never running concurrently" made per-persona standing
  # containers the wrong model: this way NixOS eval/deploy cost is O(1)
  # regardless of how many personas exist, not O(n).
  #
  # How identity gets in: NOTHING persona-specific is a Nix option here.
  # secretsEnvFile / gitConfigFile / signingKeyFile are bind-mounted at
  # FIXED container paths; their HOST-SIDE content gets rewritten by the
  # invocation script (nix-config/scripts/persona-invoke.sh) immediately
  # before each `machinectl start`, and the model is passed as a
  # `hermes -m ...` runtime flag, not a NixOS config value (confirmed
  # working live 2026-08-08 testing juan's standing container). autoStart
  # = false — the invoke script starts/stops it per call. ephemeral =
  # true (mkContainer's default) means the rootfs resets on every start,
  # so no persona's session state leaks into the next invocation.
  #
  # Rights/egress tiers per persona (role-tags → different egress
  # profiles) are NOT built yet — this first version ships one
  # restrictLan-only profile shared by everyone, same as juan's original
  # container. Revisit once more than one tier is actually needed.
  options.my.containers.persona-runtime = {
    enable = lib.mkEnableOption "Generic persona-agnostic agent worker container";
    ip = lib.mkOption { type = lib.types.str; };
    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Started on-demand by the invoke script, not at host boot.";
    };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      description = "Scratch state dir. ephemeral=true wipes the container rootfs each start regardless, but this survives host reboots between invocations — not meant to carry one persona's state into the next.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "4G";
    };
    secretsEnvFile = lib.mkOption {
      type = lib.types.str;
      description = "Fixed HOST path bind-mounted as the agent's environmentFiles (e.g. GEMINI_API_KEY=...). Content rewritten per invocation by persona-invoke.sh — not persona-specific at the Nix level.";
    };
    gitConfigFile = lib.mkOption {
      type = lib.types.str;
      description = "Fixed HOST path bind-mounted to /etc/gitconfig. Content (user.name/email/signingkey/gpg.format/commit.gpgsign) rewritten per invocation.";
    };
    signingKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "Fixed HOST path bind-mounted to the container path gitConfigFile's user.signingkey points at (/run/secrets/signing-key). Content rewritten per invocation.";
    };
    egress = {
      restrictLan = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Block agent-initiated connections into private address space —
          same rationale as openclaw/hermes-juan: an autonomous agent with
          shell + git access must not be able to pivot into the LAN.
        '';
      };
      lanAllowlist = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
    };
  } // tlsOpts;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # Bind-mount source files must exist before the container's systemd
      # mount units can attach to them, even before persona-invoke.sh has
      # ever run — empty placeholders, real content comes from the first
      # invocation.
      {
        systemd.tmpfiles.rules = [
          "f ${cfg.secretsEnvFile} 0600 root root - -"
          "f ${cfg.gitConfigFile} 0644 root root - -"
          "f ${cfg.signingKeyFile} 0600 root root - -"
        ];
      }

      # ─── Host-side egress containment (mirrors openclaw.nix/hermes-juan.nix) ───
      (lib.mkIf cfg.egress.restrictLan (
        let
          containerIp = lib.head (lib.splitString "/" cfg.ip);
          allowRules = lib.concatMapStringsSep "\n        " (
            dst: "ip saddr ${containerIp} ip daddr ${dst} accept"
          ) cfg.egress.lanAllowlist;
        in
        {
          networking.nftables.tables.zt-persona-runtime-egress = {
            family = "inet";
            content = ''
              chain forward {
                type filter hook forward priority filter; policy accept;
                ip saddr ${containerIp} ct state { established, related } accept
                ${allowRules}
                ip saddr ${containerIp} ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } limit rate 6/minute log prefix "zt-persona-runtime-egress drop: "
                ip saddr ${containerIp} ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } counter drop
              }
            '';
          };
        }
      ))

      (mkContainer {
        inherit config;
        name = "persona-runtime";
        inherit cfg;
        innerConfig = {
          imports = [ inputs.hermes.nixosModules.default ];

          networking.nameservers = lib.mkForce [
            "1.1.1.1"
            "8.8.8.8"
          ];

          services.hermes-agent = {
            enable = true;
            package = inputs.hermes.packages.${pkgs.stdenv.hostPlatform.system}.messaging;

            # Runnable via `machinectl shell persona-runtime
            # /run/current-system/sw/bin/hermes -m <model> -z '...'` — model
            # is always a runtime flag here, never a Nix value, since this
            # container is shared across every persona.
            addToSystemPackages = true;

            environmentFiles = [ "/run/secrets/agent.env" ];

            settings = {
              # Same upstream packaging gap as hermes.nix/hermes-juan.nix —
              # ModuleNotFoundError: hermes_state_common. Not used anyway.
              kanban.dispatch_in_gateway = false;
            };
          };

          # Other personas' declared tools (claude-code, aider, gemini-cli —
          # see nix-config/personas.nix's `tool` field per persona) get
          # added here as they're actually invoked through this container,
          # not preemptively for all of them.
          environment.systemPackages = [ ];

          # NOT programs.git — that bakes a static /etc/gitconfig at build
          # time, which defeats the point (one shared container, N
          # personas). /etc/gitconfig is bind-mounted directly instead
          # (see bindMounts below); persona-invoke.sh writes real
          # user.name/email/signingkey content into it before each start.

          networking.firewall.enable = true;
        };
        bindMounts = {
          "/run/secrets/agent.env" = {
            hostPath = cfg.secretsEnvFile;
            isReadOnly = true;
          };
          "/etc/gitconfig" = {
            hostPath = cfg.gitConfigFile;
            isReadOnly = true;
          };
          "/run/secrets/signing-key" = {
            hostPath = cfg.signingKeyFile;
            isReadOnly = true;
          };
          "/var/lib/hermes" = {
            hostPath = cfg.hostDataDir;
            isReadOnly = false;
          };
        };
      })
    ]
  );
}
