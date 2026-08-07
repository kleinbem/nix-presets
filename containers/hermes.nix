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
  # attrsOf: one instance per name (e.g. "main" for the original
  # Discord-facing bot, "juan" for a persona-scoped worker) — each gets its
  # own container, own IP, own state dir, own optional git identity. Added
  # 2026-08-07 when personas started needing their own Hermes workers;
  # the original singular config becomes the "main" instance.
  options.my.containers.hermes = lib.mkOption {
    default = { };
    type = lib.types.attrsOf (
      lib.types.submodule (
        {
          options = {
            enable = lib.mkEnableOption "Hermes Agent (Nous Research) Container instance";
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
            gitIdentity = {
              enable = lib.mkEnableOption "git commit-signing identity for this instance (persona workers)";
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
                  Host path to the persona's DECRYPTED private ed25519 signing key
                  (e.g. config.sops.secrets.juan_signing_key.path). Bind-mounted
                  read-only into the container and used directly as git's
                  user.signingkey (gpg.format=ssh) — ssh-keygen -Y sign accepts
                  the private key file directly, no agent needed.
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
        }
      )
    );
  };

  config = lib.mkMerge (
    lib.mapAttrsToList (
      instanceName: icfg:
      let
        containerName = "hermes-${instanceName}";
      in
      lib.mkIf icfg.enable (
        lib.mkMerge [
          # ─── Host-side egress containment (mirrors openclaw.nix) ───────────
          (lib.mkIf icfg.egress.restrictLan (
            let
              containerIp = lib.head (lib.splitString "/" icfg.ip);
              allowRules = lib.concatMapStringsSep "\n        " (
                dst: "ip saddr ${containerIp} ip daddr ${dst} accept"
              ) icfg.egress.lanAllowlist;
            in
            {
              networking.nftables.tables."zt-${containerName}-egress" = {
                family = "inet";
                content = ''
                  chain forward {
                    type filter hook forward priority filter; policy accept;
                    ip saddr ${containerIp} ct state { established, related } accept
                    ${allowRules}
                    ip saddr ${containerIp} ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } limit rate 6/minute log prefix "zt-${containerName}-egress drop: "
                    ip saddr ${containerIp} ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } counter drop
                  }
                '';
              };
            }
          ))
          (mkContainer {
            inherit config;
            name = containerName;
            cfg = icfg;
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
                # `machinectl shell hermes-<name> /run/current-system/sw/bin/hermes`
                # for first-time provider auth, and shares state with the gateway.
                # This is also the entry point for a herdr-tracked persona session:
                # attach to that shell inside a herdr pane instead of a bare
                # machinectl invocation to get session tracking/notifications.
                addToSystemPackages = true;

                environmentFiles = lib.optional (icfg.secretsFile != null) "/run/secrets/hermes.env";

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
                // lib.optionalAttrs (icfg.ollamaUrl != "" || icfg.vllmUrl != "") {
                  model = {
                    provider = "custom";
                    base_url = if icfg.ollamaUrl != "" then icfg.ollamaUrl else icfg.vllmUrl;
                    # No `default` model set — first run: `/model custom` inside
                    # a session auto-detects it if exactly one model is loaded,
                    # or run `hermes model` to pick explicitly.
                  };
                }
                // lib.optionalAttrs icfg.discord.enable {
                  gateway.platforms.discord.enabled = true;
                };
              };

              # Git commit-signing identity for persona workers (e.g. juan) —
              # system-wide /etc/gitconfig since the container has no other
              # users. gpg.format=ssh + user.signingkey pointing directly at
              # the private key file: ssh-keygen -Y sign works against a
              # private key path with no agent needed.
              programs.git = lib.mkIf icfg.gitIdentity.enable {
                enable = true;
                config = {
                  user.name = icfg.gitIdentity.name;
                  user.email = icfg.gitIdentity.email;
                  user.signingkey = "/run/secrets/git-signing-key";
                  commit.gpgsign = true;
                  gpg.format = "ssh";
                };
              };

              networking.firewall.enable = true;
            };
            bindMounts =
              (lib.optionalAttrs (icfg.secretsFile != null) {
                "/run/secrets/hermes.env" = {
                  hostPath = icfg.secretsFile;
                  isReadOnly = true;
                };
              })
              // (lib.optionalAttrs (icfg.gitIdentity.enable && icfg.gitIdentity.signingKeyFile != null) {
                "/run/secrets/git-signing-key" = {
                  hostPath = icfg.gitIdentity.signingKeyFile;
                  isReadOnly = true;
                };
              })
              // {
                # Container rootfs is ephemeral (recreated on rebuild) — state
                # (memory, sessions, skills, cron) must live on the host.
                "/var/lib/hermes" = {
                  hostPath = icfg.hostDataDir;
                  isReadOnly = false;
                };
              };
          })
        ]
      )
    ) cfg
  );
}
