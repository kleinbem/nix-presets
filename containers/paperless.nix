{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.paperless;
  inherit (self.lib) mkContainer;
in
{
  imports = [ ../nixosModules/backup-engine ];

  options.my.containers.paperless = {
    enable = lib.mkEnableOption "Paperless-ngx Native Container";
    ip = lib.mkOption {
      type = lib.types.str;
    };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/images/paperless";
      description = "Host directory for Paperless data persistence.";
    };
    hostConsumptionDir = lib.mkOption {
      type = lib.types.str;
      default = "/home/martin/Documents/Archive/00_Inbox";
      description = "Host directory to watch for new documents.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "2G";
    };
    passwordFile = lib.mkOption {
      # str, not path: a path value would copy the secret into the store.
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path to a file containing the admin password.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkContainer {
        inherit config;
        name = "paperless";
        cfg = cfg // {
          privateUsers = "no"; # Consistant with other containers for bind-mount ease
        };
        # The default 90s start timeout kills a first-run `manage.py migrate`
        # on weak hardware, and it then loops forever.
        timeout = "10m";
        # Must pre-exist on the host before nspawn starts — see factory.nix's
        # subDirs doc comment.
        subDirs = [ "postgresql" ];

        innerConfig =
          { pkgs, ... }:
          {
            # Major pinned: an unpinned default changes under a nixpkgs bump
            # and Postgres then refuses to start on the existing datadir.
            services.postgresql.package = pkgs.postgresql_17;

            # Security Hardening for the container's NixOS system
            systemd.services.paperless-consumer.serviceConfig = {
              ProtectSystem = lib.mkForce "strict";
              ProtectHome = lib.mkForce true;
              PrivateTmp = lib.mkForce true;
            };

            services.paperless = {
              enable = true;
              address = "0.0.0.0";
              port = 28981;
              # Use Redis for better performance with task queue
              consumptionDirIsPublic = true;
              # Postgres over SQLite, as paperless-ngx recommends: concurrent
              # writers and clean pg_dump backups. Persisted by the
              # /var/lib/postgresql bindMount below.
              database.createLocally = true;
              settings = {
                PAPERLESS_OCR_LANGUAGE = "deu+eng"; # Common for European users, adjust if needed
                # No PAPERLESS_OCR_MODE: "clean" is a PAPERLESS_OCR_CLEAN value
                # (already the default), and an invalid OCR_MODE crashes startup.
                PAPERLESS_TIME_ZONE = "Europe/London";
                PAPERLESS_ADMIN_USER = "admin";

                # SSO via Caddy's Authentik forward-auth. Django exposes the
                # forwarded X-Authentik-Username header as HTTP_X_AUTHENTIK_USERNAME.
                PAPERLESS_ENABLE_HTTP_REMOTE_USER = "true";
                PAPERLESS_HTTP_REMOTE_USER_HEADER = "HTTP_X_AUTHENTIK_USERNAME";
                PAPERLESS_LOGOUT_REDIRECT_URL = "https://auth.kleinbem.dev/";
              };
              # Fixed path, not gated on cfg.passwordFile: container-factory
              # builds innerConfig once for all hosts (ADR-002), so cfg here is
              # never the host's and the gate would always be false. The host
              # bindMount and the activation script below fill this path.
              passwordFile = "/run/secrets/paperless_password";
            };

            networking.firewall.allowedTCPPorts = [ 28981 ];

            # Ensure the secret file is reachable inside
            system.activationScripts.paperless-secrets.text = ''
              mkdir -p /run/secrets
              if [ -f /run/secrets/paperless_password_host ]; then
                cp /run/secrets/paperless_password_host /run/secrets/paperless_password
                chown paperless:paperless /run/secrets/paperless_password
              fi
            '';
          };

        bindMounts = {
          # Persist the whole data directory
          "/var/lib/paperless" = {
            hostPath = cfg.hostDataDir;
            isReadOnly = false;
          };
          "/var/lib/paperless/consume" = {
            hostPath = cfg.hostConsumptionDir;
            isReadOnly = false;
          };
          # Postgres data dir — persists across container rebuilds the same
          # way /var/lib/paperless does. postgres has a static NixOS system
          # uid, so ownership stays consistent across independently-built
          # container closures.
          "/var/lib/postgresql" = {
            hostPath = "${cfg.hostDataDir}/postgresql";
            isReadOnly = false;
          };
          "/run/secrets/paperless_password_host" = lib.mkIf (cfg.passwordFile != null) {
            hostPath = cfg.passwordFile;
            isReadOnly = true;
          };
        };
      })
      {
        # hostConsumptionDir is a standalone host path, not a subdirectory
        # of hostDataDir — subDirs (mkContainer, above) doesn't cover it.
        # No chown here because nspawn handles it or we use non-private users.
        systemd.tmpfiles.rules = [
          "d ${cfg.hostConsumptionDir} 0755 1000 100 - -"
        ];
      }
      {
        # Documents are the irreplaceable part and can grow large → bulk
        # (restic); the db is small → secure. The raw Postgres datadir is
        # excluded: the dump is the consistent copy.
        my.backup.items = {
          paperless-db = {
            tier = "secure";
            postgres = [ { machine = "paperless"; } ];
          };
          paperless-documents = {
            tier = "bulk";
            paths = [ cfg.hostDataDir ];
            exclude = [ "${cfg.hostDataDir}/postgresql" ];
          };
        };
      }
    ]
  );
}
