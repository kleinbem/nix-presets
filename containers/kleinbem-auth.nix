{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.kleinbem-auth;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.kleinbem-auth = {
    enable = lib.mkEnableOption "kleinbem-auth container (better-auth social login for kleinbem.dev)";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      description = "Host dir bind-mounted to /var/lib/kleinbem-auth — holds the SQLite DB.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "256M";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Port the Node service listens on (Caddy reverse-proxies to it).";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "login.kleinbem.dev";
      description = ''
        Public origin (BETTER_AUTH_URL). Deliberately NOT auth.kleinbem.dev —
        that hostname is reserved for the separate persona-Authentik plan.
      '';
    };
    trustedOrigins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "https://kleinbem.dev" ];
      description = "Site origins allowed to call the auth API (CORS + CSRF allowlist).";
    };
    cookieDomain = lib.mkOption {
      type = lib.types.str;
      default = ".kleinbem.dev";
      description = "Parent domain for cross-subdomain session cookies.";
    };

    # Secret file paths (inside the container). Host-level bind mounts, resolved
    # via sops on the deploying host — never part of the container closure, so
    # the container-factory passes dummies.
    betterAuthSecretFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "File containing BETTER_AUTH_SECRET (openssl rand -hex 32).";
    };
    googleClientIdFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    googleClientSecretFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    facebookClientIdFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    facebookClientSecretFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "kleinbem-auth";
    inherit cfg;
    innerConfig = {
      # Compose the runtime env file from sops-materialised secret files.
      systemd.services.kleinbem-auth-env-setup = {
        description = "Materialise kleinbem-auth environment from sops files";
        wantedBy = [ "kleinbem-auth.service" ];
        before = [ "kleinbem-auth.service" ];
        serviceConfig.Type = "oneshot";
        script = ''
          umask 077
          {
            printf 'BETTER_AUTH_URL=%s\n' 'https://${cfg.domain}'
            printf 'TRUSTED_ORIGINS=%s\n' '${lib.concatStringsSep "," cfg.trustedOrigins}'
            printf 'COOKIE_DOMAIN=%s\n' '${cfg.cookieDomain}'
            printf 'DB_PATH=%s\n' '/var/lib/kleinbem-auth/auth.db'
            printf 'PORT=%d\n' ${toString cfg.port}
            ${lib.optionalString (
              cfg.betterAuthSecretFile != null
            ) "printf 'BETTER_AUTH_SECRET=%s\\n' \"$(cat ${cfg.betterAuthSecretFile})\""}
            ${lib.optionalString (
              cfg.googleClientIdFile != null
            ) "printf 'GOOGLE_CLIENT_ID=%s\\n' \"$(cat ${cfg.googleClientIdFile})\""}
            ${lib.optionalString (
              cfg.googleClientSecretFile != null
            ) "printf 'GOOGLE_CLIENT_SECRET=%s\\n' \"$(cat ${cfg.googleClientSecretFile})\""}
            ${lib.optionalString (
              cfg.facebookClientIdFile != null
            ) "printf 'FACEBOOK_CLIENT_ID=%s\\n' \"$(cat ${cfg.facebookClientIdFile})\""}
            ${lib.optionalString (
              cfg.facebookClientSecretFile != null
            ) "printf 'FACEBOOK_CLIENT_SECRET=%s\\n' \"$(cat ${cfg.facebookClientSecretFile})\""}
          } > /run/kleinbem-auth.env
        '';
      };

      systemd.services.kleinbem-auth = {
        description = "kleinbem-auth (better-auth social login)";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network.target"
          "kleinbem-auth-env-setup.service"
        ];
        serviceConfig = {
          EnvironmentFile = "/run/kleinbem-auth.env";
          ExecStartPre = "${pkgs.kleinbem-auth}/bin/kleinbem-auth-migrate";
          ExecStart = "${pkgs.kleinbem-auth}/bin/kleinbem-auth";
          DynamicUser = true;
          StateDirectory = "kleinbem-auth";
          WorkingDirectory = "/var/lib/kleinbem-auth";
          Restart = "on-failure";
          RestartSec = "5s";
          # hardening
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          ReadWritePaths = [ "/var/lib/kleinbem-auth" ];
        };
      };

      networking.firewall.allowedTCPPorts = [ cfg.port ];
    };

    bindMounts = {
      "/var/lib/kleinbem-auth" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    };
  });
}
