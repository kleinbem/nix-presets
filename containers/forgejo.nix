{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.forgejo;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
  oidcOpts = import ../lib/oidc-options.nix {
    inherit lib;
    defaultName = "forgejo";
  };

  hasAdmin = cfg.admin.passwordFile != null;
  hasOidc = cfg.oidc.enable;

  # Fixed paths the secret files are bind-mounted to inside the container.
  adminPasswordPath = "/run/secrets/forgejo-admin-password";
  oidcSecretPath = "/run/secrets/forgejo-oidc-secret";
in
{
  imports = [ ../nixosModules/backup-engine ];

  options.my.containers.forgejo = {
    enable = lib.mkEnableOption "Forgejo container (self-hosted Git forge)";
    ip = lib.mkOption {
      type = lib.types.str;
      description = "Container IP on the cbr0 bridge.";
    };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/images/forgejo";
      description = "Host directory holding repositories, LFS objects and the PostgreSQL database.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Internal HTTP port.";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "git.kleinbem.dev";
      description = "Public host (no scheme). Caddy terminates TLS in front.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "1G";
    };
    ssh = {
      enable = lib.mkEnableOption "Forgejo's built-in SSH server for git over SSH";
      port = lib.mkOption {
        type = lib.types.port;
        default = 2222;
        description = "Port the built-in SSH server listens on and advertises in clone URLs.";
      };
    };
    actions.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Forgejo Actions. Runners are registered separately (forgejo-runner on a host).";
    };

    admin = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "martin";
        description = "Local admin account, created once if missing.";
      };
      email = lib.mkOption {
        type = lib.types.str;
        default = "martin@kleinbem.dev";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Host path to the admin password. null ⇒ no admin is created (first OIDC user is not admin).";
      };
    };
  }
  // tlsOpts
  // {
    oidc = oidcOpts.oidc // {
      clientSecretFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Host path to the Authentik client secret. Required when oidc.enable.";
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = !hasOidc || cfg.oidc.clientSecretFile != null;
            message = "my.containers.forgejo.oidc.enable needs oidc.clientSecretFile.";
          }
        ];
      }
      (mkContainer {
        inherit config;
        name = "forgejo";
        inherit cfg;
        subDirs = [ "postgresql" ];
        innerConfig =
          { config, ... }:
          {
            # Major pinned: an unpinned default changes under a nixpkgs bump
            # and Postgres then refuses to start on the existing datadir.
            services.postgresql.package = pkgs.postgresql_17;

            # Pinned: a dynamic id can shift when the container's user list
            # changes, and only the top-level dirs get re-chowned, not the
            # repositories inside (same trap as buzz.nix).
            users.users.forgejo.uid = 990;
            users.groups.forgejo.gid = 990;

            services.forgejo = {
              enable = true;
              database = {
                type = "postgres";
                createDatabase = true;
              };
              lfs.enable = true;
              settings = {
                server = {
                  DOMAIN = cfg.domain;
                  ROOT_URL = "https://${cfg.domain}/";
                  HTTP_ADDR = "0.0.0.0";
                  HTTP_PORT = cfg.port;
                  DISABLE_SSH = !cfg.ssh.enable;
                  START_SSH_SERVER = cfg.ssh.enable;
                  SSH_PORT = cfg.ssh.port;
                  SSH_LISTEN_PORT = cfg.ssh.port;
                };
                session.COOKIE_SECURE = true;
                # No open sign-up. With OIDC, accounts come only from Authentik.
                service = {
                  DISABLE_REGISTRATION = !hasOidc;
                  ALLOW_ONLY_EXTERNAL_REGISTRATION = hasOidc;
                  SHOW_REGISTRATION_BUTTON = false;
                };
                # A new Authentik login gets its own account; one whose name
                # matches a local account must log in locally once to link.
                oauth2_client = {
                  ENABLE_AUTO_REGISTRATION = true;
                  USERNAME = "nickname";
                  ACCOUNT_LINKING = "login";
                  OPENID_CONNECT_SCOPES = lib.concatStringsSep " " cfg.oidc.scopes;
                };
                repository.DEFAULT_PRIVATE = "private";
                mirror = {
                  ENABLED = true;
                  DEFAULT_INTERVAL = "8h";
                  MIN_INTERVAL = "10m";
                };
                actions.ENABLED = cfg.actions.enable;
                mailer.ENABLED = false;
              };
            };

            # The CLI for admin work: run it as the forgejo user, e.g.
            # `runuser -u forgejo -- forgejo --work-path /var/lib/forgejo admin user list`.
            environment.systemPackages = [ config.services.forgejo.package ];

            # Creates the admin and the Authentik login source the NixOS module
            # leaves to the CLI. Idempotent: reruns update, never duplicate.
            systemd.services.forgejo-bootstrap = lib.mkIf (hasAdmin || hasOidc) {
              description = "Forgejo admin user and Authentik login source";
              after = [ "forgejo.service" ];
              requires = [ "forgejo.service" ];
              wantedBy = [ "multi-user.target" ];
              path = [
                config.services.forgejo.package
                pkgs.gawk
                pkgs.gnugrep
              ];
              environment = {
                USER = "forgejo";
                HOME = "/var/lib/forgejo";
                FORGEJO_WORK_DIR = "/var/lib/forgejo";
                FORGEJO_CUSTOM = "/var/lib/forgejo/custom";
              };
              serviceConfig = {
                Type = "oneshot";
                # add-oauth fetches Authentik's discovery document, so keep
                # trying while Authentik is down or still starting.
                Restart = "on-failure";
                RestartSec = "30s";
                User = "forgejo";
                Group = "forgejo";
                WorkingDirectory = "/var/lib/forgejo";
              };
              script =
                lib.optionalString hasAdmin ''
                  if ! forgejo admin user list --admin | awk 'NR>1 {print $2}' | grep -qx ${lib.escapeShellArg cfg.admin.name}; then
                    forgejo admin user create --admin \
                      --username ${lib.escapeShellArg cfg.admin.name} \
                      --email ${lib.escapeShellArg cfg.admin.email} \
                      --password "$(cat ${adminPasswordPath})" \
                      --must-change-password=false
                  fi
                ''
                + lib.optionalString hasOidc ''
                  args=(
                    --name authentik
                    --provider openidConnect
                    --key ${lib.escapeShellArg cfg.oidc.clientId}
                    --secret "$(cat ${oidcSecretPath})"
                    --auto-discover-url ${lib.escapeShellArg cfg.oidc.issuerUrl}
                    --skip-local-2fa
                  )
                  for s in ${lib.escapeShellArgs cfg.oidc.scopes}; do args+=(--scopes "$s"); done
                  id=$(forgejo admin auth list | awk '$2 == "authentik" {print $1}')
                  if [ -n "$id" ]; then
                    forgejo admin auth update-oauth --id "$id" "''${args[@]}"
                  else
                    forgejo admin auth add-oauth "''${args[@]}"
                  fi
                '';
            };

            networking.firewall.allowedTCPPorts = [ cfg.port ] ++ lib.optional cfg.ssh.enable cfg.ssh.port;
          };

        bindMounts = {
          "/var/lib/postgresql" = {
            hostPath = "${cfg.hostDataDir}/postgresql";
            isReadOnly = false;
          };
          "/var/lib/forgejo" = {
            hostPath = cfg.hostDataDir;
            isReadOnly = false;
          };
        }
        // lib.optionalAttrs hasAdmin {
          ${adminPasswordPath} = {
            hostPath = cfg.admin.passwordFile;
            isReadOnly = true;
          };
        }
        // lib.optionalAttrs hasOidc {
          ${oidcSecretPath} = {
            hostPath = cfg.oidc.clientSecretFile;
            isReadOnly = true;
          };
        };
      })
      {
        my.backup.items = {
          forgejo-db = {
            tier = "secure";
            postgres = [ { machine = "forgejo"; } ];
          };
          forgejo-data = {
            tier = "secure";
            paths = [ cfg.hostDataDir ];
            exclude = [
              "${cfg.hostDataDir}/postgresql"
              "${cfg.hostDataDir}/log"
              "${cfg.hostDataDir}/data/tmp"
            ];
          };
        };
      }
    ]
  );
}
