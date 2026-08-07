{ self, inputs }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.hermes-juan;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  # Juan's persona-scoped Hermes worker — a separate preset from hermes.nix
  # (2026-08-07), not an attrsOf instance of it. attrsOf-of-submodule +
  # mkContainer reproducibly triggers "infinite recursion encountered" when
  # evaluated via container-factory's catalogue+deployedContainers
  # construction (confirmed even with a maximally minimal attrsOf schema —
  # a structural conflict, not something specific to gitIdentity/egress).
  # This duplicates most of hermes.nix's shape; if more personas need their
  # own worker later, either copy this pattern again or properly debug the
  # attrsOf path first — don't scale duplication past 2-3 without doing that.
  options.my.containers.hermes-juan = {
    enable = lib.mkEnableOption "Hermes Agent (Nous Research) Container — juan persona worker";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "4G";
    };
    model = lib.mkOption {
      type = lib.types.str;
      default = "gemini/gemini-2.5-pro";
      description = ''
        litellm-style provider/model string, matching juan's declared model
        in nix-config/personas.nix. hermes-agent has a native Gemini adapter
        (agent/gemini_native_adapter.py in the hermes-agent flake) — talks
        directly to Google's API, no local LiteLLM proxy involved. Requires
        GEMINI_API_KEY or GOOGLE_API_KEY in secretsFile.
      '';
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host path to an env file bind-mounted as Hermes's environmentFiles — GEMINI_API_KEY (or GOOGLE_API_KEY) goes here.";
    };
    gitIdentity = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Git user.name — e.g. \"Juan González\".";
      };
      email = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Git user.email — e.g. \"juan@kleinbem.dev\".";
      };
      signingKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Host path to juan's DECRYPTED private ed25519 signing key (e.g.
          config.sops.secrets.juan_signing_key.path). Bind-mounted read-only
          into the container and used directly as git's user.signingkey
          (gpg.format=ssh) — ssh-keygen -Y sign accepts the private key file
          directly, no agent needed.
        '';
      };
    };
    egress = {
      restrictLan = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Block hermes-initiated connections into private address space
          (LAN, NetBird mesh, link-local) at the HOST's forward chain, same
          rationale as openclaw: an autonomous agent with direct shell
          execution and git access must not be able to pivot into the LAN.
          Internet egress stays open. Sibling containers on the same bridge
          (e.g. ollama) remain reachable regardless — bridge traffic never
          hits this forward hook — so local-LLM access does not need an
          allowlist entry.
        '';
      };
      lanAllowlist = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "10.0.0.5" ];
        description = "IPs/CIDRs inside the blocked private ranges hermes MAY initiate connections to.";
      };
    };
  } // tlsOpts;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # ─── Host-side egress containment (mirrors openclaw.nix/hermes.nix) ───
      (lib.mkIf cfg.egress.restrictLan (
        let
          containerIp = lib.head (lib.splitString "/" cfg.ip);
          allowRules = lib.concatMapStringsSep "\n        " (
            dst: "ip saddr ${containerIp} ip daddr ${dst} accept"
          ) cfg.egress.lanAllowlist;
        in
        {
          networking.nftables.tables.zt-hermes-juan-egress = {
            family = "inet";
            content = ''
              chain forward {
                type filter hook forward priority filter; policy accept;
                ip saddr ${containerIp} ct state { established, related } accept
                ${allowRules}
                ip saddr ${containerIp} ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } limit rate 6/minute log prefix "zt-hermes-juan-egress drop: "
                ip saddr ${containerIp} ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } counter drop
              }
            '';
          };
        }
      ))
      (mkContainer {
        inherit config;
        name = "hermes-juan";
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

            # Lets `hermes model` / `hermes setup` be run interactively via
            # `machinectl shell hermes-juan /run/current-system/sw/bin/hermes`
            # for first-time provider auth, and shares state with the
            # gateway. This is also the entry point for a herdr-tracked
            # session: attach to that shell inside a herdr pane instead of a
            # bare machinectl invocation to get session tracking/
            # notifications.
            addToSystemPackages = true;

            environmentFiles = lib.optional (cfg.secretsFile != null) "/run/secrets/hermes-juan.env";

            settings = {
              # Same upstream packaging gap as hermes.nix's main instance —
              # ModuleNotFoundError: hermes_state_common. Not used anyway.
              kanban.dispatch_in_gateway = false;
              model = cfg.model;
            };
          };

          # Git commit-signing identity — system-wide /etc/gitconfig since
          # the container has no other users. gpg.format=ssh + signingkey
          # pointing directly at the private key file: ssh-keygen -Y sign
          # works against a private key path with no agent needed.
          programs.git = lib.mkIf (cfg.gitIdentity.signingKeyFile != null) {
            enable = true;
            config = {
              user.name = cfg.gitIdentity.name;
              user.email = cfg.gitIdentity.email;
              user.signingkey = "/run/secrets/git-signing-key";
              commit.gpgsign = true;
              gpg.format = "ssh";
            };
          };

          networking.firewall.enable = true;
        };
        bindMounts =
          (lib.optionalAttrs (cfg.gitIdentity.signingKeyFile != null) {
            "/run/secrets/git-signing-key" = {
              hostPath = cfg.gitIdentity.signingKeyFile;
              isReadOnly = true;
            };
          })
          // (lib.optionalAttrs (cfg.secretsFile != null) {
            "/run/secrets/hermes-juan.env" = {
              hostPath = cfg.secretsFile;
              isReadOnly = true;
            };
          })
          // {
            "/var/lib/hermes" = {
              hostPath = cfg.hostDataDir;
              isReadOnly = false;
            };
          };
      })
    ]
  );
}
