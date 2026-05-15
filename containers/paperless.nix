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
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a file containing the admin password.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.recursiveUpdate
      (mkContainer {
        inherit config;
        name = "paperless";
        cfg = cfg // {
          privateUsers = "no"; # Consistant with other containers for bind-mount ease
        };

        innerConfig = _: {
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
            settings = {
              PAPERLESS_OCR_LANGUAGE = "deu+eng"; # Common for European users, adjust if needed
              PAPERLESS_OCR_MODE = "clean";
              PAPERLESS_TIME_ZONE = "Europe/London";
              PAPERLESS_ADMIN_USER = "admin";

              # --- SSO Integration (Authelia) ---
              PAPERLESS_ENABLE_HTTP_REMOTE_USER = "true";
              PAPERLESS_HTTP_REMOTE_USER_HEADER = "HTTP_REMOTE_USER";
              PAPERLESS_LOGOUT_REDIRECT_URL = "https://authelia.local/"; # Adjust if your domain is different
            };
            passwordFile = lib.mkIf (cfg.passwordFile != null) "/run/secrets/paperless_password";
          };

          # Database is managed automatically by the module (PostgreSQL by default)

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
          "/run/secrets/paperless_password_host" = lib.mkIf (cfg.passwordFile != null) {
            hostPath = cfg.passwordFile;
            isReadOnly = true;
          };
        };
      })
      {
        # Ensure host bind-mount directories exist
        systemd.services."container@paperless".preStart = ''
          mkdir -p ${cfg.hostDataDir}
          mkdir -p ${cfg.hostConsumptionDir}
          # No chown here because nspawn handles it or we use non-private users
        '';
      }
  );
}
