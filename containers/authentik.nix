# Authentik IdP: persona OIDC and the kleinbem.dev visitor login, one instance.
# nixpkgs has a package but no NixOS module, so authentik runs from the official
# image via podman; Postgres stays native. Since 2025.10 it needs no Redis, and
# the server runs migrations on startup.
{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.authentik;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };

  image = "ghcr.io/goauthentik/server:2026.8.3";

  # In-container paths the *File options are bind-mounted to; the env-setup
  # script reads them into /run/authentik.env.
  secretKeyPath = "/run/secrets/authentik-secret-key";
  postgresPasswordPath = "/run/secrets/authentik-postgres-password";
  bootstrapAdminPasswordPath = "/run/secrets/authentik-bootstrap-admin-password";
  bootstrapApiTokenPath = "/run/secrets/authentik-bootstrap-api-token";
in
{
  imports = [ ../nixosModules/backup-engine ];

  options.my.containers.authentik = {
    enable = lib.mkEnableOption "Authentik IdP Container (persona OIDC, Matrix federation, sigstore — Phase 3+)";
    ip = lib.mkOption {
      type = lib.types.str;
      description = "Container IP on the cbr0 bridge.";
    };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      description = "Host directory bind-mounted for Postgres data + app media/certs/templates.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "1G";
      description = "Authentik + embedded Postgres run in this container — 1G is comfortable for ~50 persona users.";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "auth.kleinbem.dev";
      description = "Public-facing hostname (Caddy reverse-proxies to ip:9000).";
    };
    secretKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host path (e.g. a sops secret's .path) to a file containing the AUTHENTIK_SECRET_KEY — bind-mounted into the container internally. Required at first start. Generate with: openssl rand -hex 32";
    };
    postgresPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host path (e.g. a sops secret's .path) to a file containing the Postgres password — bind-mounted into the container internally. Not actually enforced (local Postgres uses trust auth over loopback, scoped to this container only — see innerConfig), but authentik still requires the env var set.";
    };
    bootstrapAdminPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host path (e.g. a sops secret's .path) to a file containing the initial admin (akadmin) password — bind-mounted into the container internally. Used only on first start.";
    };
    bootstrapApiTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Host path (e.g. a sops secret's .path) to a file containing the
        initial API token for akadmin — bind-mounted into the container
        internally. This is what Terraform uses to provision persona users
        from personas.nix — without it, you have to bootstrap users by hand
        through the web UI on first run.
      '';
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkContainer {
        inherit config;
        name = "authentik";
        inherit cfg;
        # Bundles the 15m pull timeout, nesting caps/devices, and podman's
        # own registries.conf — see factory.nix's usesPodman doc comment.
        usesPodman = true;
        # Must pre-exist on the host before nspawn starts — see factory.nix's
        # subDirs doc comment.
        subDirs = [ "postgresql" ];
        innerConfig =
          { pkgs, ... }:
          {
            virtualisation = {
              oci-containers = {
                backend = "podman";
                containers = {
                  authentik-server = {
                    inherit image;
                    cmd = [ "server" ];
                    environmentFiles = [ "/run/authentik.env" ];
                    # host networking: reaches native Postgres via
                    # 127.0.0.1, and the app's own 0.0.0.0:9000/9443 bind
                    # becomes directly reachable on this container's own
                    # bridge IP — no port mapping needed.
                    extraOptions = [ "--network=host" ];
                  };
                  authentik-worker = {
                    inherit image;
                    cmd = [ "worker" ];
                    environmentFiles = [ "/run/authentik.env" ];
                    # Since 2026.8 the worker also binds :9000/:9443/:9300 and,
                    # sharing the host netns, can grab them before the server
                    # (server crash-loops, :9000 returns 404). Park the
                    # worker's listeners on other loopback ports.
                    environment = {
                      AUTHENTIK_LISTEN__HTTP = "127.0.0.1:9001";
                      AUTHENTIK_LISTEN__HTTPS = "127.0.0.1:9444";
                      AUTHENTIK_LISTEN__METRICS = "127.0.0.1:9301";
                    };
                    extraOptions = [ "--network=host" ];
                  };
                };
              };
            };

            # Trust auth is fine: this container is the only tenant. TCP on
            # loopback so the host-networked podman containers can reach it.
            services.postgresql = {
              enable = true;
              # Pinned major: a nixpkgs default bump would refuse the existing datadir.
              package = pkgs.postgresql_17;
              enableTCPIP = true;
              ensureDatabases = [ "authentik" ];
              ensureUsers = [
                {
                  name = "authentik";
                  ensureDBOwnership = true;
                }
              ];
              authentication = lib.mkForce ''
                local all all trust
                host all all 127.0.0.1/32 trust
              '';
            };

            # Build /run/authentik.env from the secret files plus fixed settings,
            # and order the generated podman-authentik-* units after it and Postgres.
            systemd.services = {
              authentik-env-setup = {
                description = "Materialise authentik environment from sops files";
                before = [
                  "podman-authentik-server.service"
                  "podman-authentik-worker.service"
                ];
                serviceConfig.Type = "oneshot";
                script = ''
                  umask 077
                  {
                    ${lib.optionalString (
                      cfg.secretKeyFile != null
                    ) ''printf "AUTHENTIK_SECRET_KEY=%s\n" "$(cat ${secretKeyPath})"''}
                    ${lib.optionalString (
                      cfg.postgresPasswordFile != null
                    ) ''printf "AUTHENTIK_POSTGRESQL__PASSWORD=%s\n" "$(cat ${postgresPasswordPath})"''}
                    ${lib.optionalString (
                      cfg.bootstrapAdminPasswordFile != null
                    ) ''printf "AUTHENTIK_BOOTSTRAP_PASSWORD=%s\n" "$(cat ${bootstrapAdminPasswordPath})"''}
                    ${lib.optionalString (
                      cfg.bootstrapApiTokenFile != null
                    ) ''printf "AUTHENTIK_BOOTSTRAP_TOKEN=%s\n" "$(cat ${bootstrapApiTokenPath})"''}
                    printf "AUTHENTIK_POSTGRESQL__HOST=127.0.0.1\n"
                    printf "AUTHENTIK_POSTGRESQL__NAME=authentik\n"
                    printf "AUTHENTIK_POSTGRESQL__USER=authentik\n"
                    printf "AUTHENTIK_POSTGRESQL__SSLMODE=disable\n"
                    printf "AUTHENTIK_WEB__BASE_URL=https://%s\n" "${cfg.domain}"
                  } > /run/authentik.env
                '';
              };

              "podman-authentik-server" = {
                after = [
                  "postgresql.service"
                  "authentik-env-setup.service"
                  "network.target"
                ];
                wants = [
                  "postgresql.service"
                  "authentik-env-setup.service"
                ];
              };

              "podman-authentik-worker" = {
                after = [
                  "postgresql.service"
                  "authentik-env-setup.service"
                ];
                wants = [
                  "postgresql.service"
                  "authentik-env-setup.service"
                ];
              };
            };

            networking.firewall.allowedTCPPorts = [
              9000 # HTTP
              9443 # HTTPS (used internally; Caddy fronts publicly)
            ];

            environment.systemPackages = [ pkgs.podman ];
          };

        bindMounts = {
          # postgres has a static NixOS uid, so ownership survives rebuilt closures.
          "/var/lib/postgresql" = {
            hostPath = "${cfg.hostDataDir}/postgresql";
            isReadOnly = false;
          };
          # Podman image storage is bind-mounted by usesPodman.
        }
        // lib.optionalAttrs (cfg.secretKeyFile != null) {
          ${secretKeyPath} = {
            hostPath = cfg.secretKeyFile;
            isReadOnly = true;
          };
        }
        // lib.optionalAttrs (cfg.postgresPasswordFile != null) {
          ${postgresPasswordPath} = {
            hostPath = cfg.postgresPasswordFile;
            isReadOnly = true;
          };
        }
        // lib.optionalAttrs (cfg.bootstrapAdminPasswordFile != null) {
          ${bootstrapAdminPasswordPath} = {
            hostPath = cfg.bootstrapAdminPasswordFile;
            isReadOnly = true;
          };
        }
        // lib.optionalAttrs (cfg.bootstrapApiTokenFile != null) {
          ${bootstrapApiTokenPath} = {
            hostPath = cfg.bootstrapApiTokenFile;
            isReadOnly = true;
          };
        };
      })
      {
        # The IdP's whole state lives in its native Postgres (no media dir in
        # use) → one pg_dumpall inside the `authentik` machine.
        my.backup.items.authentik = {
          tier = "secure";
          postgres = [ { machine = "authentik"; } ];
        };
      }
    ]
  );
}
