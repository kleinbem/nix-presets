{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.dev-db;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  imports = [ ../nixosModules/backup-engine ];

  options.my.containers.dev-db = {
    enable = lib.mkEnableOption "Developer Database Container (PostgreSQL + Redis)";
    ip = lib.mkOption {
      type = lib.types.str;
      description = "Container IP on the cbr0 bridge.";
    };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/images/dev-db";
      description = "Host directory holding persistent state for postgres and redis.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "2G";
    };
    initialDatabases = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "dev"
        "test"
        "msf"
      ];
      description = "Databases pre-created on first initialization.";
    };
    postgresPort = lib.mkOption {
      type = lib.types.port;
      default = 5432;
    };
    redisPort = lib.mkOption {
      type = lib.types.port;
      default = 6379;
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkContainer {
        inherit config;
        name = "dev-db";
        inherit cfg;
        subDirs = [
          "postgresql"
          "redis"
        ];
        innerConfig = {
          services.postgresql = {
            enable = true;
            package = pkgs.postgresql_17;
            enableTCPIP = true;
            settings.port = cfg.postgresPort;
            ensureDatabases = cfg.initialDatabases;
            ensureUsers = [
              {
                name = "dev";
                ensureDBOwnership = true;
                ensureClauses = {
                  superuser = true;
                  login = true;
                  createdb = true;
                };
              }
            ];
            # Local trust for dev environment
            authentication = lib.mkForce ''
              local all all trust
              host all all all trust
            '';
          };

          services.redis.servers."" = {
            enable = true;
            bind = "0.0.0.0";
            port = cfg.redisPort;
          };

          networking.firewall.allowedTCPPorts = [
            cfg.postgresPort
            cfg.redisPort
          ];
        };

        bindMounts = {
          "/var/lib/postgresql" = {
            hostPath = "${cfg.hostDataDir}/postgresql";
            isReadOnly = false;
          };
          "/var/lib/redis" = {
            hostPath = "${cfg.hostDataDir}/redis";
            isReadOnly = false;
          };
        };
      })
      {
        my.backup.items.dev-db = {
          tier = "secure";
          postgres = [ { machine = "dev-db"; } ];
          paths = [ "${cfg.hostDataDir}/redis" ];
        };
      }
    ]
  );
}
