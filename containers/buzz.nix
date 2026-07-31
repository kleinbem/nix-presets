# Buzz (Block/Jack Dorsey) — Nostr-based team chat + git + AI-agent
# workspace, self-hosted natively (no Docker/Podman): the relay binary is
# built from source (pkgs/buzz-relay.nix) and Postgres/Redis/Typesense/MinIO
# all run as ordinary NixOS services inside this one container. Deliberately
# NOT using enableNesting + Podman's dockerCompat the way langfuse/anythingllm/
# ente do — Buzz is ~10 days old at time of writing (2026-07-31) and pulling
# in upstream's own Docker images on top of that immaturity was judged not
# worth it; building from source keeps the whole stack auditable and
# consistent with how openclaw/hermes/most of this fleet already runs.
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
in
{
  options.my.containers.buzz = {
    enable = lib.mkEnableOption "Buzz (Nostr chat/git/agent workspace) Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "3G"; # relay + postgres + redis + typesense + minio
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Host path to an EnvironmentFile= (KEY=VALUE lines) bind-mounted for
        every service that reads secrets that way: BUZZ_RELAY_PRIVATE_KEY
        (32-byte hex Nostr key), MINIO_ROOT_USER, MINIO_ROOT_PASSWORD,
        BUZZ_S3_ACCESS_KEY, BUZZ_S3_SECRET_KEY (the last two are the same
        values as the MINIO_ROOT_* pair, just under the name the relay reads
        them as — duplicate the value under both keys in the file).
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
          networking.firewall.enable = true;

          # ── Postgres 17, local-only, peer auth (no password to manage) ──
          services.postgresql = {
            enable = true;
            package = pkgs.postgresql_17;
            ensureDatabases = [ "buzz" ];
            ensureUsers = [
              {
                name = "buzz";
                ensureDBOwnership = true;
              }
            ];
          };
          users.users.buzz = {
            isSystemUser = true;
            group = "buzz";
          };
          users.groups.buzz = { };

          # ── Redis, local-only ────────────────────────────────────────────
          services.redis.servers.buzz = {
            enable = true;
            port = 6379;
            bind = "127.0.0.1";
          };

          # ── Typesense (search) ───────────────────────────────────────────
          services.typesense = {
            enable = true;
            apiKeyFile = "/run/secrets/buzz-typesense-api-key"; # raw value, no KEY=VALUE
            settings = {
              api-address = "127.0.0.1";
              api-port = 8108;
            };
          };

          # ── MinIO (S3-compatible object storage) ─────────────────────────
          services.minio = {
            enable = true;
            listenAddress = "127.0.0.1:9000";
            consoleAddress = "127.0.0.1:9001";
            rootCredentialsFile = "/run/secrets/buzz.env"; # MINIO_ROOT_USER/PASSWORD
          };
          # Bucket doesn't exist on first boot — create it idempotently once
          # MinIO is actually accepting connections.
          systemd.services.buzz-minio-bucket = {
            description = "Ensure the buzz-media bucket exists in MinIO";
            after = [ "minio.service" ];
            requires = [ "minio.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              EnvironmentFile = "/run/secrets/buzz.env";
            };
            path = [ pkgs.minio-client ];
            script = ''
              mc alias set buzzlocal http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
              mc mb --ignore-existing buzzlocal/buzz-media
            '';
          };

          # ── The relay itself ──────────────────────────────────────────────
          users.users.buzz-relay = {
            isSystemUser = true;
            group = "buzz-relay";
          };
          users.groups.buzz-relay = { };

          systemd.tmpfiles.rules = [
            "d /var/lib/buzz-relay 0750 buzz-relay buzz-relay - -"
            "d /var/lib/buzz-relay/repos 0750 buzz-relay buzz-relay - -"
          ];

          systemd.services.buzz-relay = {
            description = "Buzz WebSocket relay";
            after = [
              "network.target"
              "postgresql.service"
              "redis-buzz.service"
              "typesense.service"
              "buzz-minio-bucket.service"
            ];
            requires = [
              "postgresql.service"
              "redis-buzz.service"
              "typesense.service"
              "buzz-minio-bucket.service"
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
              RELAY_URL = cfg.relayUrl;
              BUZZ_GIT_REPO_PATH = "/var/lib/buzz-relay/repos";
              RUST_LOG = "buzz_relay=info,buzz_datastore=info,buzz_db=info,buzz_auth=info,buzz_pubsub=info";
            };
            # BUZZ_RELAY_PRIVATE_KEY, BUZZ_S3_ACCESS_KEY/SECRET_KEY (same
            # values as MINIO_ROOT_USER/PASSWORD, duplicated under the name
            # the relay reads) all come from secretsFile — see its option doc.
            serviceConfig = {
              EnvironmentFile = "/run/secrets/buzz.env";
              ExecStart = "${buzzRelay}/bin/buzz-relay";
              User = "buzz-relay";
              Group = "buzz-relay";
              Restart = "always";
              RestartSec = 5;
            };
          };

          networking.firewall.allowedTCPPorts = [ 3000 ];
        };
        bindMounts =
          (lib.optionalAttrs (cfg.secretsFile != null) {
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
            "/var/lib/minio" = {
              hostPath = "${cfg.hostDataDir}/minio";
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
