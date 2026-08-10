# Buzz (Block/Jack Dorsey) — Nostr-based team chat + git + AI-agent
# workspace, self-hosted natively (no Docker/Podman): the relay binary is
# built from source (pkgs/buzz-relay.nix) and Postgres/Redis/Typesense/Garage
# all run as ordinary NixOS services inside this one container. Deliberately
# NOT using enableNesting + Podman's dockerCompat the way langfuse/anythingllm/
# ente do — Buzz is ~10 days old at time of writing (2026-07-31) and pulling
# in upstream's own Docker images on top of that immaturity was judged not
# worth it; building from source keeps the whole stack auditable and
# consistent with how openclaw/hermes/most of this fleet already runs.
#
# S3-compatible storage is Garage, not MinIO — nixpkgs marked minio insecure
# and abandoned (2026-08-02: CVE-2026-40344 among others, upstream stopped
# fixing issues), and MinIO was already rejected fleet-wide on 2026-06-27 in
# favor of Garage (see hosts/nixos-nvme/garage.nix for the host-level
# instance backing restic/tofu-state; this is a SEPARATE single-node Garage
# instance private to the buzz container, not that one — self-containment is
# the same rationale as Postgres/Redis/Typesense above).
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
  buzzRelay = pkgs.callPackage ../pkgs/buzz-relay.nix { };

  # Evaluated by the CONSUMING host (nixos-nvme, etc.), not baked into the
  # container-factory build — see the comment on RELAY_URL's removal from
  # systemd.services.buzz-relay.environment above. bindMounts (below) is a
  # host-level option, so this derivation and its content genuinely differ
  # per real deploying host, unlike anything inside innerConfig.
  relayUrlEnvFile = pkgs.writeText "buzz-relay-url.env" "RELAY_URL=${cfg.relayUrl}\n";
in
{
  options.my.containers.buzz = {
    enable = lib.mkEnableOption "Buzz (Nostr chat/git/agent workspace) Container";
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
      # ─── Host-side egress containment (mirrors openclaw.nix/hermes.nix) ─
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
        innerConfig = {
          networking.firewall = {
            enable = true;
            allowedTCPPorts = [ 3000 ];
          };

          users = {
            users = {
              # Static user (not the module's DynamicUser) so the
              # bind-mounted data dir has stable ownership across restarts —
              # see the services.garage comment below.
              #
              # uid/gid PINNED, not left to isSystemUser's dynamic
              # allocation: confirmed live 2026-08-09 that adding the
              # typesense user below shifted garage's auto-allocated uid
              # (996 -> 997), orphaning its already-on-disk data
              # (/var/lib/garage/meta's files, e.g. node_key, stayed
              # owned by 996) under the new uid — Garage panicked
              # ("Unable to read or generate node ID: Permission
              # denied") since only the top-level StateDirectory gets
              # auto-rechowned on a uid change, not existing file
              # contents. Pinning every static user here at its
              # currently-resolved id freezes them against any future
              # reshuffle from unrelated user-list edits.
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
              # Same reasoning as garage — services.typesense defaults to
              # DynamicUser, which conflicts with bind-mounting a host dir
              # straight onto /var/lib/typesense (systemd tries to migrate
              # it to /var/lib/private/typesense and fails with "Device or
              # resource busy" on an already-mounted, non-empty directory —
              # confirmed live 2026-08-09). See the systemd.services.typesense
              # override below.
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
              # Peer auth compares the connecting OS username to the
              # requested Postgres role directly unless mapped — buzz-relay
              # (the systemd service's own OS user, isolated from postgres/
              # garage/etc. for directory-ownership reasons) requests role
              # "buzz", so the module's own default `local all all peer`
              # rejected it outright ("Peer authentication failed for user
              # buzz", confirmed live 2026-08-09). identMap translates
              # buzz-relay → buzz for that one rule; the plain `peer`
              # fallback below preserves default behavior (e.g. interactive
              # `psql` as OS user postgres/root) for everything else.
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
            # Single-node, private to this container — same package/settings
            # shape as hosts/nixos-nvme/garage.nix but scoped to buzz's own
            # data dir.
            garage = {
              enable = true;
              package = pkgs.garage_2; # matches hosts/nixos-nvme/garage.nix (v2.3.0)
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

                  # NOT RELAY_URL = cfg.relayUrl here (tried first, wrong):
                  # this whole `environment` block gets BAKED into the
                  # container's systemd unit at BUILD time — fine for
                  # constants, but this container is deployed standalone
                  # (my.services.container-updater.containers), which means
                  # the store path that actually ships is built ONCE by
                  # hosts/container-factory (placeholder cfg, relayUrl =
                  # "wss://buzz.example.invalid") and that exact closure is
                  # what every consuming host's `update-container@buzz`
                  # pulls verbatim — a real host's own `cfg.relayUrl` here
                  # would just be evaluated and discarded, never built.
                  # Confirmed live 2026-08-10: the desktop client got a 404
                  # ("no community is configured for this host") because the
                  # running relay had literally registered buzz.example.invalid
                  # as its community, not the real address. secretsFile/
                  # typesenseApiKeyFile don't have this problem because
                  # bindMounts (below) is a HOST-level option, evaluated by
                  # each consuming host's OWN config, not baked into the
                  # shared factory build — so RELAY_URL needs the same
                  # bind-mounted-file treatment, see relayUrlEnvFile below.

                  # Schema was never created — the one-time init never ran
                  # this. Without it every background job (push matching,
                  # reminders, community scan) loops failing against tables
                  # that don't exist ("relation events/communities/
                  # push_match_queue does not exist"), confirmed live
                  # 2026-08-10, even though the process itself stays up.
                  # Upstream's own deploy docs (engineering.block.xyz/blog/
                  # run-your-own-buzz-relay) set this permanently, not as a
                  # one-shot — safe to leave on, applies pending migrations
                  # idempotently on every start.
                  BUZZ_AUTO_MIGRATE = "true";

                  # Garage cannot pass this: its own docs state atomic
                  # conditional writes (If-Match/If-None-Match CAS) are
                  # "structurally impossible... due to the lack of a
                  # consensus algorithm" — a permanent design choice, not a
                  # version gap. buzz-relay's git-over-S3 storage leans on
                  # that CAS as a formal correctness axiom (A3) for its
                  # linearizability proof (docs/git-on-object-storage.md
                  # upstream) — with the probe on, Garage fails it outright
                  # (confirmed live 2026-08-09: "expected exactly 1 winner
                  # among 32 classified observers, got 32").
                  #
                  # Deliberate tradeoff, not a fix: disabling this only
                  # skips the startup check — Garage still can't provide
                  # the guarantee, so a genuine same-repo concurrent push
                  # could theoretically lose an update. Accepted here
                  # because (a) this is a single-operator/low-concurrency
                  # instance where that race is rare, (b) the git-hosting
                  # feature isn't in active use — chat/relay/media (the
                  # actual reason this container exists) don't touch this
                  # code path at all, and (c) the alternative (a second
                  # self-hosted object store, MinIO, just for this) was
                  # already rejected fleet-wide 2026-06-27 for real CVEs.
                  # Revisit if buzz's git hosting ever sees real concurrent
                  # use — MinIO (or real AWS S3) is upstream's tested
                  # reference backend for that guarantee, Garage is not.
                  BUZZ_GIT_CONFORMANCE_PROBE = "false";
                };
                # BUZZ_RELAY_PRIVATE_KEY, BUZZ_S3_ACCESS_KEY/SECRET_KEY (same
                # values as MINIO_ROOT_USER/PASSWORD, duplicated under the name
                # the relay reads) all come from secretsFile — see its option doc.
                # relay-url.env carries RELAY_URL — see the comment on its
                # removal from the `environment` block above for why it has
                # to arrive this way instead.
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
            hostPath = "${relayUrlEnvFile}";
            isReadOnly = true;
          };
        }
        // (lib.optionalAttrs (cfg.secretsFile != null) {
          "/run/secrets/buzz.env" = {
            hostPath = cfg.secretsFile;
            isReadOnly = true;
          };
        })
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
    ]
  );
}
# --- ONE-TIME INIT after first apply (imperative; run against the buzz
# container — e.g. `nixos-container run buzz -- garage ...` or a root shell
# via `machinectl shell buzz`) ------------------------------------------------
# Mirrors hosts/nixos-nvme/garage.nix's own one-time init. garage.service
# comes up fine with no layout/bucket/key yet (buzz-relay will start too, but
# its S3 calls will fail until this is done):
#
#   # 1. give this (only) node storage capacity and apply the layout:
#   garage layout assign -z buzz -c 10G "$(garage node id -q | cut -d@ -f1)"
#   garage layout apply --version 1
#
#   # 2. create the bucket + a scoped key for the relay:
#   garage bucket create buzz-media
#   garage key create buzz-relay-key
#   garage bucket allow --read --write buzz-media --key buzz-relay-key
#   # → note the Key ID + Secret (shown once): put them into kleinbem-secrets
#     as buzz_s3_access_key / buzz_s3_secret_key (see hosts/nixos-nvme/secrets.nix's
#     "buzz.env" template), `sops updatekeys`, then `just apply` + restart
#     buzz-relay so it picks up real S3 credentials.
