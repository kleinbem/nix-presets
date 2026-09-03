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

  # Fixed paths the sops secret files are bind-mounted to *inside* the
  # container. The cfg.*File host attrs hold sops-nix paths resolved on the
  # deploying host; the inner env-setup script only ever reads these
  # constants, so the cached closure is byte-identical whether built by the
  # container-factory (ADR-002 standalone build) or a real host. Reading
  # cfg.*File directly in the inner script instead — as this preset used to —
  # bakes the factory's `/run/secrets/factory-dummy` into the closure the
  # host then runs, and the real sops path never takes effect (the host-side
  # innerConfig is discarded for standalone containers). Same pattern as
  # vaultwarden.nix.
  betterAuthSecretPath = "/run/secrets/kleinbem-auth-better-auth-secret";
  googleClientIdPath = "/run/secrets/kleinbem-auth-google-client-id";
  googleClientSecretPath = "/run/secrets/kleinbem-auth-google-client-secret";
  facebookClientIdPath = "/run/secrets/kleinbem-auth-facebook-client-id";
  facebookClientSecretPath = "/run/secrets/kleinbem-auth-facebook-client-secret";

  hasBetterAuthSecret = cfg.betterAuthSecretFile != null;
  hasGoogleClientId = cfg.googleClientIdFile != null;
  hasGoogleClientSecret = cfg.googleClientSecretFile != null;
  hasFacebookClientId = cfg.facebookClientIdFile != null;
  hasFacebookClientSecret = cfg.facebookClientSecretFile != null;
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
      # Fixed user — the SQLite DB persists via a host bind-mount onto
      # /var/lib/kleinbem-auth (the container is ephemeral). DynamicUser +
      # StateDirectory can't take ownership of a pre-existing bind mount
      # (systemd exit 238/STATE_DIRECTORY), so use a fixed uid and let
      # tmpfiles own the mounted dir each boot.
      users.users.kleinbem-auth = {
        isSystemUser = true;
        group = "kleinbem-auth";
        home = "/var/lib/kleinbem-auth";
      };
      users.groups.kleinbem-auth = { };

      networking.firewall.allowedTCPPorts = [ cfg.port ];

      systemd = {
        tmpfiles.rules = [
          "d /var/lib/kleinbem-auth 0750 kleinbem-auth kleinbem-auth - -"
        ];

        services = {
          # Compose the runtime env file from sops-materialised secret files.
          kleinbem-auth-env-setup = {
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
                ${lib.optionalString hasBetterAuthSecret
                  "printf 'BETTER_AUTH_SECRET=%s\\n' \"$(cat ${betterAuthSecretPath})\""
                }
                ${lib.optionalString hasGoogleClientId
                  "printf 'GOOGLE_CLIENT_ID=%s\\n' \"$(cat ${googleClientIdPath})\""
                }
                ${lib.optionalString hasGoogleClientSecret
                  "printf 'GOOGLE_CLIENT_SECRET=%s\\n' \"$(cat ${googleClientSecretPath})\""
                }
                ${lib.optionalString hasFacebookClientId
                  "printf 'FACEBOOK_CLIENT_ID=%s\\n' \"$(cat ${facebookClientIdPath})\""
                }
                ${lib.optionalString hasFacebookClientSecret
                  "printf 'FACEBOOK_CLIENT_SECRET=%s\\n' \"$(cat ${facebookClientSecretPath})\""
                }
              } > /run/kleinbem-auth.env
            '';
          };

          kleinbem-auth = {
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
              User = "kleinbem-auth";
              Group = "kleinbem-auth";
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
        };
      };
    };

    bindMounts = {
      "/var/lib/kleinbem-auth" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    }
    // lib.optionalAttrs hasBetterAuthSecret {
      ${betterAuthSecretPath} = {
        hostPath = cfg.betterAuthSecretFile;
        isReadOnly = true;
      };
    }
    // lib.optionalAttrs hasGoogleClientId {
      ${googleClientIdPath} = {
        hostPath = cfg.googleClientIdFile;
        isReadOnly = true;
      };
    }
    // lib.optionalAttrs hasGoogleClientSecret {
      ${googleClientSecretPath} = {
        hostPath = cfg.googleClientSecretFile;
        isReadOnly = true;
      };
    }
    // lib.optionalAttrs hasFacebookClientId {
      ${facebookClientIdPath} = {
        hostPath = cfg.facebookClientIdFile;
        isReadOnly = true;
      };
    }
    // lib.optionalAttrs hasFacebookClientSecret {
      ${facebookClientSecretPath} = {
        hostPath = cfg.facebookClientSecretFile;
        isReadOnly = true;
      };
    };
  });
}
