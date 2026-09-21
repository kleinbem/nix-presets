# Authentik IdP Container (persona OIDC, Matrix federation, sigstore — Phase
# 3+; also the shared kleinbem.dev visitor-login replacement for
# kleinbem-auth, one instance serving both — see 2026-09-21 design note).
#
# nixpkgs has NO `services.authentik` NixOS module (confirmed live
# 2026-09-21 against the pinned nixpkgs rev: only `pkgs.authentik` exists,
# under pkgs/by-name/au/authentik) — the module this file used to assume
# never existed, so this preset had never actually worked. Rather than
# reverse-engineer authentik's internals against a bare package (attempted
# first, real uncertainty around startup sequencing/bootstrap behavior that
# the maintained image just doesn't have), this runs the official image via
# podman — same OCI-in-nspawn pattern already proven by anythingllm.nix,
# reused for the same reason: no native module, upstream-maintained image
# is the trustworthy source of truth for how the app actually boots.
#
# Postgres itself DOES have a mature native NixOS module, so it stays
# native (services.postgresql, same local-trust-auth precedent as
# langfuse.nix/paperless.nix) rather than also being podman-ized — only
# authentik itself needs the image.
#
# Confirmed against authentik's real requirements (docker-compose.yml at
# goauthentik.io/docker-compose.yml, 2026-09-21): Redis was fully removed
# as a dependency as of the 2025.10 release — Postgres alone is required.
# `command: server` / `command: worker` are the only two processes;
# migrations run automatically as part of server startup, no separate
# migrate step.
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

  # Fixed in-container path the env-setup script writes to and the podman
  # containers read via environmentFiles — the *File options below are
  # host-side sops paths and only reach the container via the bindMounts
  # further down (same pattern as kleinbem-auth.nix).
  secretKeyPath = "/run/secrets/authentik-secret-key";
  postgresPasswordPath = "/run/secrets/authentik-postgres-password";
  bootstrapAdminPasswordPath = "/run/secrets/authentik-bootstrap-admin-password";
  bootstrapApiTokenPath = "/run/secrets/authentik-bootstrap-api-token";
in
{
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
    lib.recursiveUpdate
      (mkContainer {
        inherit config;
        name = "authentik";
        inherit cfg;
        # Image pull can be slow on first start — same fix anythingllm.nix
        # needed (default 90s TimeoutStartSec kills the container mid-pull).
        timeout = "15m";
        enableNesting = true; # Required for OCI-in-nspawn
        innerConfig =
          { pkgs, ... }:
          {
            virtualisation = {
              podman = {
                enable = true;
                dockerCompat = true;
              };
              # Same fix anythingllm.nix needed: podman's own registries.conf
              # inside this container is separate from the host's.
              containers.registries.settings.unqualified-search-registries = [
                "docker.io"
              ];

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
                    extraOptions = [ "--network=host" ];
                  };
                };
              };
            };

            # Postgres has a real native NixOS module, unlike authentik
            # itself — no reason to also podman-ize it. Local-only, trust
            # auth (this container is the only tenant), same precedent as
            # langfuse.nix/paperless.nix. enableTCPIP + a loopback-only
            # trust rule so the podman containers (host-networked, so they
            # see this container's own 127.0.0.1) can reach it.
            services.postgresql = {
              enable = true;
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

            # Compose the environment file the podman containers load via
            # environmentFiles, from sops-templated secrets plus the fixed
            # local-Postgres/base-URL settings that don't need to be secret;
            # then extend oci-containers' auto-generated
            # podman-authentik-{server,worker} units with the dependency
            # ordering podman's own module doesn't expose as a
            # container-level option.
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
          # Postgres — static NixOS system uid, ownership stays consistent
          # across independently-built container closures (same note as
          # paperless.nix).
          "/var/lib/postgresql" = {
            hostPath = "${cfg.hostDataDir}/postgresql";
            isReadOnly = false;
          };
          # Podman's own image/layer storage. The container's root ("/") is
          # an EPHEMERAL 2G tmpfs (fixed, not tied to memoryLimit) — without
          # this, podman unpacks the (multi-GB, two containers: server +
          # worker) authentik image straight into that 2G tmpfs and hits
          # "no space left on device" on every pull, crash-looping forever
          # (confirmed live 2026-09-21: restart counter 42 and climbing,
          # 18GB+ of repeated failed-pull traffic). anythingllm.nix gets
          # away without this only because its single image is much
          # smaller and it runs one container, not two.
          "/var/lib/containers" = {
            hostPath = "${cfg.hostDataDir}/containers";
            isReadOnly = false;
          };
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
        # Ensure host bind-mount directories exist before nspawn starts —
        # same pattern as paperless.nix / syncthing.nix.
        systemd.services."container@authentik".preStart = ''
          mkdir -p ${cfg.hostDataDir}/postgresql
          mkdir -p ${cfg.hostDataDir}/containers
        '';
      }
  );
}
