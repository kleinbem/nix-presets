{ self, inputs }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.langfuse;
  inherit (self.lib) mkContainer;

  dbPasswordPath = "/run/secrets/langfuse-db-password";
  # The app container is the only client allowed into Postgres.
  appIp = builtins.head (lib.splitString "/" cfg.ip);
in
{
  options.my.containers.langfuse = {
    enable = lib.mkEnableOption "Langfuse Telemetry Stack";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "4G";
    };
    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    dbPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Host path (e.g. a sops secret's .path) to a file containing the
        password of the `langfuse` Postgres role. Re-applied on every DB
        container start. The same value must appear in secretsFile's
        DATABASE_URL (postgresql://langfuse:<pw>@<db-ip>:5432/langfuse).
        Unset = no password = the app's login fails closed. Generate
        with: openssl rand -hex 32
      '';
    };
  }
  // import ../lib/tls-options.nix { inherit lib; };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # 1. Native NixOS Database Container
      (mkContainer {
        inherit config;
        name = "langfuse-db";
        cfg = {
          inherit (cfg) autoStart;
          ip = "10.85.46.124/24"; # Static IP for the DB container
          hostDataDir = "${cfg.hostDataDir}/db";
          # postgres refuses to start against a data directory group/world
          # can touch, so this can't use the factory's 1000:100 default —
          # give it the real uid/gid the postgresql module assigns
          # (config.ids.uids/gids.postgres, verified via `nix eval` against
          # this flake's pinned nixpkgs: both 71).
          dataDirOwner = 71;
          dataDirGroup = 71;
        };
        # Used to be `trust` for all of 10.85.46.0/24 plus an
        # initialScript creating a `postgres`/'postgres' superuser — i.e.
        # every container on that bridge got passwordless superuser, and
        # the app connected as superuser too. Now: a dedicated `langfuse`
        # role owning only its own database, scram password, reachable
        # only from the app container's IP; superuser is local-socket
        # peer only.
        #
        # RE-ENABLING with the old (Apr 2026 trial) datadir still at
        # ${cfg.hostDataDir}/db: its tables are owned by `postgres`, which
        # the new `langfuse` role can't use. Either wipe that dir (it was
        # only ever a trial), or pg_dump it first and restore with
        # `pg_restore --no-owner --role=langfuse -d langfuse`.
        innerConfig = {
          services.postgresql = {
            enable = true;
            package = pkgs.postgresql_16;
            enableTCPIP = true;
            ensureDatabases = [ "langfuse" ];
            ensureUsers = [
              {
                name = "langfuse";
                ensureDBOwnership = true;
              }
            ];
            authentication = lib.mkForce ''
              local all postgres peer
              host langfuse langfuse ${appIp}/32 scram-sha-256
            '';
          };

          # (Re-)applies the langfuse role's password from sops on every
          # start — ensureUsers creates the role but never sets one. Same
          # pattern as ente.nix's ente-db-setup: secret goes in via
          # psql's environment (\getenv) + :'var' quoting, never argv;
          # runs as root to read the root-only sops file.
          systemd.services.langfuse-db-password = {
            description = "Set Langfuse Postgres role password from sops";
            after = [ "postgresql-setup.service" ];
            requires = [ "postgresql-setup.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = lib.optionalString (cfg.dbPasswordFile != null) ''
              pw=$(cat ${dbPasswordPath})
              [ -n "$pw" ] || exit 0
              printf '%s\n' '\getenv pw LANGFUSE_PG_PASSWORD' "ALTER ROLE langfuse WITH PASSWORD :'pw';" \
                | LANGFUSE_PG_PASSWORD="$pw" ${pkgs.util-linux}/bin/runuser -u postgres -- \
                  ${pkgs.postgresql_16}/bin/psql -v ON_ERROR_STOP=1 -d postgres
            '';
          };

          networking.firewall.allowedTCPPorts = [ 5432 ];
        };
        bindMounts = {
          "/var/lib/postgresql" = {
            hostPath = "${cfg.hostDataDir}/db";
            isReadOnly = false;
          };
        }
        // lib.optionalAttrs (cfg.dbPasswordFile != null) {
          ${dbPasswordPath} = {
            hostPath = cfg.dbPasswordFile;
            isReadOnly = true;
          };
        };
      })

      # 2. Native Application Container (migrated from OCI)
      (mkContainer {
        inherit config;
        name = "langfuse";
        cfg = {
          inherit (cfg) autoStart ip memoryLimit;
          inherit (cfg) hostDataDir;
          tls = {
            enable = true;
            serverPort = 3000;
          };
        };
        # Bind-mounts to /run/secrets/langfuse.env — see factory.nix's
        # secretsFile doc comment.
        inherit (cfg) secretsFile;
        innerConfig = {
          imports = [ inputs.nix-packages.nixosModules.langfuse ];
          nixpkgs.overlays = [ inputs.nix-packages.overlays.default ];
          networking.nameservers = [
            "1.1.1.1"
            "8.8.8.8"
          ];

          # Native Langfuse Service
          services.langfuse = {
            enable = true;
            environmentFile = if (cfg.secretsFile != null) then "/run/secrets/langfuse.env" else null;
            port = 3000;
            # Optional Clickhouse if you want to test it
            # clickhouse.enable = true;
          };

          networking.firewall.allowedTCPPorts = [ 3000 ];

        };
      })

    ]
  );
}
