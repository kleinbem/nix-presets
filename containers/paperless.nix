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
        # Default 90s TimeoutStartSec kills the container mid-migration on
        # weak hardware — confirmed live on nasbook 2026-09-18: a from-empty
        # `manage.py migrate` was still pegged at ~98% CPU when systemd
        # killed it at 90s, looping forever without ever converging. Same
        # fix anythingllm.nix/monitoring.nix already needed for their own
        # slow first-time startups.
        timeout = "10m";

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
              # "clean" was set on the WRONG variable here — that's the
              # value for PAPERLESS_OCR_CLEAN (which already defaults to
              # "clean" on its own), not PAPERLESS_OCR_MODE (valid values:
              # auto/force/off/redo). Confirmed live on nasbook 2026-09-18:
              # this crashed the container at Django settings-import time,
              # every single restart, in ~17s — before it ever reached the
              # database. Every earlier fix this session (10m timeout,
              # persisting a postgres dir it doesn't even use) was chasing
              # a symptom; this was the actual bug the whole time. Just
              # omit OCR_MODE — paperless-ngx's own default ("auto") is
              # correct, and the intended "clean" behavior was already
              # the default for OCR_CLEAN regardless.
              PAPERLESS_TIME_ZONE = "Europe/London";
              PAPERLESS_ADMIN_USER = "admin";

              # --- SSO Integration (Authelia) ---
              PAPERLESS_ENABLE_HTTP_REMOTE_USER = "true";
              PAPERLESS_HTTP_REMOTE_USER_HEADER = "HTTP_REMOTE_USER";
              PAPERLESS_LOGOUT_REDIRECT_URL = "https://authelia.local/"; # Adjust if your domain is different
            };
            passwordFile = lib.mkIf (cfg.passwordFile != null) "/run/secrets/paperless_password";
          };

          # Database: services.paperless.database.createLocally defaults to
          # false in this nixpkgs version (confirmed live 2026-09-18 — no
          # postgres user/service exists in the container), so this is
          # actually SQLite under /var/lib/paperless (bind-mounted below,
          # already persisted). The /var/lib/postgresql bind mount further
          # down predates this finding and is inert; harmless to leave.

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
          # services.paperless.database.createLocally (default) sets up a
          # LOCAL postgres inside this container — its data dir was never
          # bind-mounted, so it lived on the ephemeral per-boot container
          # snapshot and got wiped + re-initdb'd from zero on every single
          # restart. Confirmed live on nasbook 2026-09-18: repeated restarts
          # (90s, then 10m timeout) never converged because the from-scratch
          # migration never got to keep any progress across a restart —
          # this was the actual root cause, not "needs more time". NixOS's
          # own postgresql module handles ownership/initdb on first use of
          # a bind-mounted dir the same way it already does for
          # /var/lib/paperless above.
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
        # Ensure host bind-mount directories exist
        systemd.services."container@paperless".preStart = ''
          mkdir -p ${cfg.hostDataDir}
          mkdir -p ${cfg.hostConsumptionDir}
          mkdir -p ${cfg.hostDataDir}/postgresql
          # No chown here because nspawn handles it or we use non-private users
        '';
      }
  );
}
