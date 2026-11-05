# Buzz (Block): Nostr chat, git and AI-agent workspace, run natively with no
# podman. The relay, Postgres, Redis, Typesense and a private single-node
# Garage (S3; nixpkgs marks MinIO insecure) all live in this one container.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.buzz;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
  buzzRelay = cfg.package;

  # Per-host settings. innerConfig is built once by container-factory with
  # placeholder values, so anything per-host must come in through a bindMount,
  # which each host evaluates itself. The file stays mounted as relay-url.env:
  # containers update apart from host switches, and a rename would break the relay.
  hexPubkey = lib.types.strMatching "[0-9a-f]{64}";
  relayHostEnvFile = pkgs.writeText "buzz-relay-host.env" (
    lib.concatStringsSep "\n" (
      [ "RELAY_URL=${cfg.relayUrl}" ]
      ++ lib.optional (cfg.pairingRelayUrl != null) "BUZZ_PAIRING_RELAY_URL=${cfg.pairingRelayUrl}"
      ++ lib.optionals cfg.membership.require [
        "BUZZ_REQUIRE_RELAY_MEMBERSHIP=true"
        # Agents attested by a member (NIP-OA) get in without their own entry.
        "BUZZ_ALLOW_NIP_OA_AUTH=true"
        "RELAY_OWNER_PUBKEY=${cfg.membership.ownerPubkey}"
      ]
      # Read by buzz-relay-members below.
      ++ [ "BUZZ_RELAY_MEMBERS=${lib.concatStringsSep " " cfg.membership.members}" ]
    )
    + "\n"
  );
in
{
  imports = [ ../nixosModules/backup-engine ];

  options.my.containers.buzz = {
    enable = lib.mkEnableOption "Buzz (Nostr chat/git/agent workspace) Container";
    package = lib.mkPackageOption pkgs "buzz-relay" { };
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "3G"; # relay + postgres + redis + typesense + garage
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Host path to an EnvironmentFile= (KEY=VALUE lines) bind-mounted for
        every service that reads secrets that way: BUZZ_RELAY_PRIVATE_KEY
        (32-byte hex Nostr key), GARAGE_RPC_SECRET (32-byte hex, `openssl
        rand -hex 32`), GARAGE_ADMIN_TOKEN (opaque, `openssl rand -base64
        32`), BUZZ_S3_ACCESS_KEY, BUZZ_S3_SECRET_KEY (a Garage S3 API key —
        NOT derived from the RPC/admin values; created via the one-time
        `garage key create`/`import` init documented at the bottom of this
        file, after which its Key ID/Secret go here).
      '';
    };
    typesenseApiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Host path to a file containing ONLY the raw Typesense API key
        (no KEY=VALUE — services.typesense.apiKeyFile cats it directly).
        The same key value also needs to appear as TYPESENSE_API_KEY=... in
        secretsFile, since the relay reads it from its environment.
      '';
    };
    relayUrl = lib.mkOption {
      type = lib.types.str;
      example = "wss://buzz.kleinbem.dev";
      description = "Public WebSocket URL — used in NIP-42 auth challenges.";
    };
    pairingRelayUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "wss://pair.buzz.kleinbem.dev";
      description = ''
        URL clients reach the container's buzz-pair-relay (port 3001) at,
        advertised in NIP-11 as `pairing_relay_url`. Needed with
        `membership.require`: clients then pair via the advertised URL (or
        `<relay>/pair`, which buzz-relay doesn't serve).
      '';
    };
    membership = {
      require = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Run a members-only relay (BUZZ_REQUIRE_RELAY_MEMBERSHIP). Only then
          does the relay publish the NIP-43 membership snapshot (kind 13534)
          that mesh-llm compute sharing uses as its roster. Also allows agents
          attested by a member (BUZZ_ALLOW_NIP_OA_AUTH).
        '';
      };
      ownerPubkey = lib.mkOption {
        type = lib.types.nullOr hexPubkey;
        default = null;
        description = "Relay owner (RELAY_OWNER_PUBKEY), 64-char hex. Required with `require`.";
      };
      members = lib.mkOption {
        type = lib.types.listOf hexPubkey;
        default = [ ];
        description = ''
          Pubkeys (64-char hex) added as members on every start via
          `buzz-admin add-member` (idempotent). Removing one here does not
          remove it from the relay; use `buzz-admin remove-member` for that.
        '';
      };
    };
    egress = {
      restrictLan = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Same rationale as openclaw/hermes: Buzz bundles AI-agent
          participation (ACP harness) and shells out to git — block
          initiated connections into private address space at the HOST's
          forward chain. Internet egress (including arbitrary Nostr relay
          federation, which this needs) stays open.
        '';
      };
      lanAllowlist = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "10.0.0.5" ];
        description = "IPs/CIDRs inside the blocked private ranges buzz MAY initiate connections to.";
      };
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = cfg.membership.require -> cfg.membership.ownerPubkey != null;
            message = "my.containers.buzz.membership.require needs membership.ownerPubkey, or nobody can administer the relay.";
          }
          {
            assertion = cfg.membership.require -> cfg.pairingRelayUrl != null;
            message = "my.containers.buzz.membership.require needs pairingRelayUrl: a members-only relay advertises NIP-43, and clients then pair via <relay>/pair, which buzz-relay doesn't serve.";
          }
        ];
      }
      # ─── Host-side egress containment (mirrors openclaw.nix) ─
      (lib.mkIf cfg.egress.restrictLan (
        let
          containerIp = lib.head (lib.splitString "/" cfg.ip);
          allowRules = lib.concatMapStringsSep "\n        " (
            dst: "ip saddr ${containerIp} ip daddr ${dst} accept"
          ) cfg.egress.lanAllowlist;
        in
        {
          networking.nftables.tables.zt-buzz-egress = {
            family = "inet";
            content = ''
              chain forward {
                type filter hook forward priority filter; policy accept;
                ip saddr ${containerIp} ct state { established, related } accept
                ${allowRules}
                ip saddr ${containerIp} ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } limit rate 6/minute log prefix "zt-buzz-egress drop: "
                ip saddr ${containerIp} ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } counter drop
              }
            '';
          };
        }
      ))
      (mkContainer {
        inherit config;
        name = "buzz";
        inherit cfg;
        # Bind-mounted to /run/secrets/buzz.env. relay-url.env and the
        # typesense key are separate bindMounts below.
        inherit (cfg) secretsFile;
        innerConfig = {
          networking.firewall = {
            enable = true;
            allowedTCPPorts = [
              3000 # buzz-relay
              3001 # buzz-pair-relay
            ];
          };

          users = {
            users = {
              # Static users, not DynamicUser, so the bind-mounted data dirs
              # keep their owner. uids are pinned: an auto-allocated uid can
              # shift when users are added, and systemd only re-chowns the top
              # StateDirectory, leaving the data unreadable.
              garage = {
                isSystemUser = true;
                group = "garage";
                uid = 997;
              };
              buzz-relay = {
                isSystemUser = true;
                group = "buzz-relay";
                uid = 998;
              };
              # With DynamicUser, systemd tries to move the bind-mounted
              # /var/lib/typesense to /var/lib/private and fails ("Device or
              # resource busy"). no-link: systemd's DynamicUser semantics, not a bug.
              typesense = {
                isSystemUser = true;
                group = "typesense";
                uid = 993;
              };
            };
            groups = {
              garage.gid = 997;
              buzz-relay.gid = 998;
              typesense.gid = 991;
            };
          };

          services = {
            # ── Postgres 17, local-only, peer auth (no password to manage) ──
            postgresql = {
              enable = true;
              package = pkgs.postgresql_17;
              ensureDatabases = [ "buzz" ];
              ensureUsers = [
                {
                  name = "buzz";
                  ensureDBOwnership = true;
                }
              ];
              # The relay runs as OS user buzz-relay but uses role buzz, which
              # plain peer auth rejects; map just that pair.
              identMap = ''
                buzz-relay-map buzz-relay buzz
              '';
              authentication = ''
                local all buzz peer map=buzz-relay-map
                local all all peer
              '';
            };

            # ── Redis, local-only ────────────────────────────────────────────
            redis.servers.buzz = {
              enable = true;
              port = 6379;
              bind = "127.0.0.1";
            };

            # ── Typesense (search) ───────────────────────────────────────────
            typesense = {
              enable = true;
              apiKeyFile = "/run/secrets/buzz-typesense-api-key"; # raw value, no KEY=VALUE
              settings.server = {
                api-address = "127.0.0.1";
                api-port = 8108;
              };
            };

            # ── Garage (S3-compatible object storage) ────────────────────────
            # Single-node, private to this container.
            garage = {
              enable = true;
              package = pkgs.garage_2;
              environmentFile = "/run/secrets/buzz.env"; # GARAGE_RPC_SECRET/ADMIN_TOKEN

              settings = {
                metadata_dir = "/var/lib/garage/meta";
                data_dir = "/var/lib/garage/data";
                db_engine = "sqlite";
                replication_factor = 1; # single node

                rpc_bind_addr = "127.0.0.1:3901";
                rpc_public_addr = "127.0.0.1:3901";

                s3_api = {
                  s3_region = "us-east-1"; # matches BUZZ_S3_REGION below
                  api_bind_addr = "127.0.0.1:9000"; # same port the relay already expects
                  # No root_domain — the relay uses path-style addressing
                  # (BUZZ_S3_ADDRESSING_STYLE below), so vhost-style routing
                  # isn't needed here.
                };

                admin.api_bind_addr = "127.0.0.1:3903"; # token via GARAGE_ADMIN_TOKEN env
              };
            };
          };

          systemd = {
            services = {
              garage.serviceConfig = {
                DynamicUser = lib.mkForce false;
                User = "garage";
                Group = "garage";
              };

              typesense.serviceConfig = {
                DynamicUser = lib.mkForce false;
                User = "typesense";
                Group = "typesense";
              };

              # ── The relay itself ──────────────────────────────────────────
              buzz-relay = {
                description = "Buzz WebSocket relay";
                after = [
                  "network.target"
                  "postgresql.service"
                  "redis-buzz.service"
                  "typesense.service"
                  "garage.service"
                ];
                requires = [
                  "postgresql.service"
                  "redis-buzz.service"
                  "typesense.service"
                  "garage.service"
                ];
                wantedBy = [ "multi-user.target" ];
                # The relay shells out to git for repo hydrate/receive-pack/upload-pack.
                path = [ pkgs.git ];
                environment = {
                  DATABASE_URL = "postgres:///buzz?host=/run/postgresql";
                  PGHOST = "/run/postgresql";
                  PGUSER = "buzz";
                  PGDATABASE = "buzz";
                  REDIS_URL = "redis://127.0.0.1:6379";
                  TYPESENSE_URL = "http://127.0.0.1:8108";
                  BUZZ_S3_ENDPOINT = "http://127.0.0.1:9000";
                  BUZZ_S3_BUCKET = "buzz-media";
                  BUZZ_S3_REGION = "us-east-1";
                  BUZZ_S3_ADDRESSING_STYLE = "path";
                  BUZZ_BIND_ADDR = "0.0.0.0:3000";
                  BUZZ_GIT_REPO_PATH = "/var/lib/buzz-relay/repos";
                  RUST_LOG = "buzz_relay=info,buzz_datastore=info,buzz_db=info,buzz_auth=info,buzz_pubsub=info";

                  # RELAY_URL is not set here: this unit is built once by
                  # container-factory with a placeholder URL. It comes from
                  # relay-url.env (relayHostEnvFile) instead.

                  # Applies pending migrations on every start, as upstream's deploy docs do.
                  BUZZ_AUTO_MIGRATE = "true";

                  # Garage has no conditional writes (If-Match CAS), which
                  # buzz's git-over-S3 relies on, so the startup probe fails.
                  # Turning it off only skips the check: concurrent pushes to
                  # one repo could lose an update. Accepted while git hosting
                  # is unused; chat and media don't use this path.
                  # upstream: https://git.deuxfleurs.fr/Deuxfleurs/garage/issues/1052
                  BUZZ_GIT_CONFORMANCE_PROBE = "false";
                };
                # Secrets come from secretsFile (see its option doc), per-host
                # settings from relay-url.env.
                serviceConfig = {
                  EnvironmentFile = [
                    "/run/secrets/buzz.env"
                    "/run/secrets/relay-url.env"
                  ];
                  ExecStart = "${buzzRelay}/bin/buzz-relay";
                  User = "buzz-relay";
                  Group = "buzz-relay";
                  Restart = "always";
                  RestartSec = 5;
                };
              };

              # NIP-AB device pairing (QR / pairing code). Stateless, no auth;
              # advertised only when the host sets pairingRelayUrl.
              buzz-pair-relay = {
                description = "Buzz device-pairing relay";
                after = [ "network.target" ];
                wantedBy = [ "multi-user.target" ];
                environment.BUZZ_PAIR_RELAY_BIND_ADDR = "0.0.0.0:3001";
                # Conservative hardening: no extra namespaces or kernel
                # protections, which conflict with the container runtime here
                # (see attic.nix, qdrant.nix).
                serviceConfig = {
                  ExecStart = "${buzzRelay}/bin/buzz-pair-relay";
                  DynamicUser = true;
                  Restart = "always";
                  RestartSec = 5;
                  CapabilityBoundingSet = "";
                  NoNewPrivileges = true;
                  ProtectSystem = "strict";
                  ProtectHome = true;
                  PrivateTmp = true;
                  RestrictAddressFamilies = [
                    "AF_INET"
                    "AF_INET6"
                  ];
                  RestrictSUIDSGID = true;
                  RestrictRealtime = true;
                  LockPersonality = true;
                  SystemCallArchitectures = "native";
                  SystemCallFilter = [ "@system-service" ];
                  UMask = "0077";
                };
              };

              # Applies membership.members (via relay-url.env, so it stays
              # per-host). buzz-admin needs the community the relay seeds at
              # startup, hence the retry; add-member is idempotent.
              buzz-relay-members = {
                description = "Apply declared Buzz relay members";
                after = [ "buzz-relay.service" ];
                wants = [ "buzz-relay.service" ];
                wantedBy = [ "multi-user.target" ];
                # Same database identity as buzz-relay (peer-mapped to role buzz).
                environment = {
                  DATABASE_URL = "postgres:///buzz?host=/run/postgresql";
                  PGHOST = "/run/postgresql";
                  PGUSER = "buzz";
                  PGDATABASE = "buzz";
                  REDIS_URL = "redis://127.0.0.1:6379";
                };
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  User = "buzz-relay";
                  Group = "buzz-relay";
                  EnvironmentFile = [
                    "/run/secrets/buzz.env"
                    "/run/secrets/relay-url.env"
                  ];
                };
                script = ''
                  for pubkey in $BUZZ_RELAY_MEMBERS; do
                    for _ in $(seq 30); do
                      ${buzzRelay}/bin/buzz-admin add-member --pubkey "$pubkey" && continue 2
                      sleep 2
                    done
                    echo "could not add member $pubkey" >&2
                    exit 1
                  done
                '';
              };
            };

            tmpfiles.rules = [
              "d /var/lib/buzz-relay 0750 buzz-relay buzz-relay - -"
              "d /var/lib/buzz-relay/repos 0750 buzz-relay buzz-relay - -"
              "d /var/lib/garage 0750 garage garage - -"
              "d /var/lib/garage/meta 0750 garage garage - -"
              "d /var/lib/garage/data 0750 garage garage - -"
            ];
          };
        };
        bindMounts = {
          "/run/secrets/relay-url.env" = {
            hostPath = "${relayHostEnvFile}";
            isReadOnly = true;
          };
        }
        // (lib.optionalAttrs (cfg.typesenseApiKeyFile != null) {
          "/run/secrets/buzz-typesense-api-key" = {
            hostPath = cfg.typesenseApiKeyFile;
            isReadOnly = true;
          };
        })
        // {
          "/var/lib/postgresql" = {
            hostPath = "${cfg.hostDataDir}/postgresql";
            isReadOnly = false;
          };
          "/var/lib/redis-buzz" = {
            hostPath = "${cfg.hostDataDir}/redis";
            isReadOnly = false;
          };
          "/var/lib/typesense" = {
            hostPath = "${cfg.hostDataDir}/typesense";
            isReadOnly = false;
          };
          "/var/lib/garage" = {
            hostPath = "${cfg.hostDataDir}/garage";
            isReadOnly = false;
          };
          "/var/lib/buzz-relay" = {
            hostPath = "${cfg.hostDataDir}/relay";
            isReadOnly = false;
          };
        };
      })
      {
        # db → secure. Git repos + Garage objects → bulk; Garage's metadata
        # is a live SQLite db (db_engine = "sqlite" above), so it's copied
        # via .backup and the live files are excluded. Redis (cache) and
        # Typesense (search index, rebuildable from Postgres) are skipped.
        my.backup.items = {
          buzz-db = {
            tier = "secure";
            postgres = [ { machine = "buzz"; } ];
          };
          buzz-data = {
            tier = "bulk";
            paths = [
              "${cfg.hostDataDir}/relay"
              "${cfg.hostDataDir}/garage"
            ];
            exclude = [ "${cfg.hostDataDir}/garage/meta/db.sqlite*" ];
            sqlite = [ "${cfg.hostDataDir}/garage/meta/db.sqlite" ];
          };
        };
      }
    ]
  );
}
# One-time init after first deploy, inside the container (`machinectl shell buzz`).
# Until then the relay runs but its S3 calls fail:
#   garage layout assign -z buzz -c 10G "$(garage node id -q | cut -d@ -f1)"
#   garage layout apply --version 1
#   garage bucket create buzz-media
#   garage key create buzz-relay-key
#   garage bucket allow --read --write buzz-media --key buzz-relay-key
# Put the Key ID + Secret (shown once) into kleinbem-secrets as
# buzz_s3_access_key / buzz_s3_secret_key, apply, then restart buzz-relay.
