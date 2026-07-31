{ self, inputs }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.hermes;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.hermes = {
    enable = lib.mkEnableOption "Hermes Agent (Nous Research) Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "4G";
    };
    ollamaUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "OpenAI-compatible base URL for a local Ollama instance, e.g. http://10.85.46.32:11434/v1";
    };
    vllmUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "OpenAI-compatible base URL for a local vLLM instance. Only used if ollamaUrl is unset.";
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Host path to an env file bind-mounted as Hermes's environmentFiles —
        DISCORD_BOT_TOKEN, DISCORD_ALLOWED_USERS, and any cloud LLM provider
        keys (ANTHROPIC_API_KEY, OPENROUTER_API_KEY, ...) go here.
      '';
    };
    discord.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable the Discord gateway. Requires DISCORD_BOT_TOKEN (and DISCORD_ALLOWED_USERS) in secretsFile.";
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
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # ─── Host-side egress containment (mirrors openclaw.nix) ───────────
      (lib.mkIf cfg.egress.restrictLan (
        let
          containerIp = lib.head (lib.splitString "/" cfg.ip);
          allowRules = lib.concatMapStringsSep "\n        " (
            dst: "ip saddr ${containerIp} ip daddr ${dst} accept"
          ) cfg.egress.lanAllowlist;
        in
        {
          networking.nftables.tables.zt-hermes-egress = {
            family = "inet";
            content = ''
              chain forward {
                type filter hook forward priority filter; policy accept;
                ip saddr ${containerIp} ct state { established, related } accept
                ${allowRules}
                ip saddr ${containerIp} ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } limit rate 6/minute log prefix "zt-hermes-egress drop: "
                ip saddr ${containerIp} ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } counter drop
              }
            '';
          };
        }
      ))
      (mkContainer {
        inherit config;
        name = "hermes";
        inherit cfg;
        innerConfig = {
          imports = [ inputs.hermes.nixosModules.default ];

          # Observed with a stray nixos-nvme-subnet address (10.85.46.1) in
          # this container's resolv.conf on hass-pi despite the host's own
          # config.my.network.hostAddress correctly being 10.85.49.1 and
          # hass-pi's own /etc/resolv.conf not containing it either —
          # mechanism unclear, but it broke Discord's DNS lookup
          # (aiohttp.ClientConnectorDNSError). Forcing known-good public
          # resolvers directly sidesteps whatever's injecting that entry.
          networking.nameservers = lib.mkForce [
            "1.1.1.1"
            "8.8.8.8"
          ];

          services.hermes-agent = {
            enable = true;
            # "messaging" variant ships discord.py/python-telegram-bot/slack-sdk
            # pre-built — we only need Discord, not the full extras kitchen sink
            # (bedrock/azure/daytona/matrix/...) that packages.default carries.
            package = inputs.hermes.packages.${pkgs.stdenv.hostPlatform.system}.messaging;

            # Lets `hermes model` / `hermes setup` be run interactively via
            # `machinectl shell hermes /run/current-system/sw/bin/hermes` for
            # first-time provider auth, and shares state with the gateway.
            addToSystemPackages = true;

            environmentFiles = lib.optional (cfg.secretsFile != null) "/run/secrets/hermes.env";

            settings = {
              # The embedded kanban/task-board dispatcher is on by default
              # upstream but currently broken in the packaged build — it
              # throws "ModuleNotFoundError: No module named
              # 'hermes_state_common'" on every tick (the file exists in
              # hermes-agent's source but isn't included in this package
              # build). We don't use the kanban/multi-agent-board feature,
              # so disable the dispatcher outright rather than patch the
              # nix packaging around a module that's not otherwise needed.
              kanban.dispatch_in_gateway = false;
            }
            // lib.optionalAttrs (cfg.ollamaUrl != "" || cfg.vllmUrl != "") {
              model = {
                provider = "custom";
                base_url = if cfg.ollamaUrl != "" then cfg.ollamaUrl else cfg.vllmUrl;
                # No `default` model set — first run: `/model custom` inside
                # a session auto-detects it if exactly one model is loaded,
                # or run `hermes model` to pick explicitly.
              };
            }
            // lib.optionalAttrs cfg.discord.enable {
              gateway.platforms.discord.enabled = true;
            };
          };

          networking.firewall.enable = true;
        };
        bindMounts =
          (lib.optionalAttrs (cfg.secretsFile != null) {
            "/run/secrets/hermes.env" = {
              hostPath = cfg.secretsFile;
              isReadOnly = true;
            };
          })
          // {
            # Container rootfs is ephemeral (recreated on rebuild) — state
            # (memory, sessions, skills, cron) must live on the host.
            "/var/lib/hermes" = {
              hostPath = cfg.hostDataDir;
              isReadOnly = false;
            };
          };
      })
    ]
  );
}
