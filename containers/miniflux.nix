{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.miniflux;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
  oidcOpts = import ../lib/oidc-options.nix {
    inherit lib;
    defaultName = "miniflux";
  };

  hasAdminCredentials = cfg.adminCredentialsFile != null;
  adminCredentialsPath = "/run/secrets/miniflux-admin.env";
in
{
  imports = [ ../nixosModules/backup-engine ];

  options.my.containers.miniflux = {
    enable = lib.mkEnableOption "Miniflux feed reader container";
    ip = lib.mkOption {
      type = lib.types.str;
      description = "Container IP on the cbr0 bridge.";
    };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/images/miniflux";
      description = "Host directory holding persistent Miniflux and PostgreSQL database state.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Internal HTTP port.";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "news.kleinbem.dev";
      description = "Public domain.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "512M";
    };
    pollingFrequency = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "Feed refresh frequency in minutes.";
    };
    adminCredentialsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host path to environment file containing ADMIN_USERNAME and ADMIN_PASSWORD.";
    };
  }
  // tlsOpts
  // oidcOpts;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkContainer {
        inherit config;
        name = "miniflux";
        inherit cfg;
        subDirs = [ "postgresql" ];
        innerConfig = {
          # Major pinned: an unpinned default changes under a nixpkgs bump
          # and Postgres then refuses to start on the existing datadir.
          services.postgresql.package = pkgs.postgresql_17;

          services.miniflux = {
            enable = true;
            createDatabaseLocally = true;
            adminCredentialsFile = if hasAdminCredentials then adminCredentialsPath else null;
            config = {
              LISTEN_ADDR = "0.0.0.0:${toString cfg.port}";
              BASE_URL = "https://${cfg.domain}";
              POLLING_FREQUENCY = cfg.pollingFrequency;
              METRICS_COLLECTOR = 1;
              CREATE_ADMIN = if hasAdminCredentials then 1 else 0;
            }
            // lib.optionalAttrs cfg.oidc.enable {
              OAUTH2_PROVIDER = "oidc";
              OAUTH2_CLIENT_ID = cfg.oidc.clientId;
              OAUTH2_REDIRECT_URL = "https://${cfg.domain}/oauth2/oidc/callback";
              OAUTH2_OIDC_DISCOVERY_ENDPOINT = cfg.oidc.issuerUrl;
              OAUTH2_USER_CREATION = 1;
            };
          };

          networking.firewall.allowedTCPPorts = [ cfg.port ];
        };

        bindMounts = {
          "/var/lib/postgresql" = {
            hostPath = "${cfg.hostDataDir}/postgresql";
            isReadOnly = false;
          };
          "/var/lib/miniflux" = {
            hostPath = cfg.hostDataDir;
            isReadOnly = false;
          };
        }
        // lib.optionalAttrs hasAdminCredentials {
          ${adminCredentialsPath} = {
            hostPath = cfg.adminCredentialsFile;
            isReadOnly = true;
          };
        };
      })
      {
        my.backup.items = {
          miniflux-db = {
            tier = "secure";
            postgres = [ { machine = "miniflux"; } ];
          };
          miniflux-data = {
            tier = "secure";
            paths = [ cfg.hostDataDir ];
            exclude = [ "${cfg.hostDataDir}/postgresql" ];
          };
        };
      }
    ]
  );
}
