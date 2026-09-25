{ self, inputs }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.ente;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };

  # Fixed in-container paths the env-setup script writes to and reads
  # from — the *File options below are host-side sops paths and only
  # reach the container via the bindMounts further down (same pattern as
  # authentik.nix).
  postgresPasswordPath = "/run/secrets/ente-postgres-password";
  minioRootPasswordPath = "/run/secrets/ente-minio-root-password";
  jwtSecretPath = "/run/secrets/ente-jwt-secret";
  keyEncryptionPath = "/run/secrets/ente-key-encryption";
  keyHashPath = "/run/secrets/ente-key-hash";
in
{
  imports = [ ../nixosModules/backup-engine ];

  options.my.containers.ente = {
    enable = lib.mkEnableOption "Ente Auth Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "auth.kleinbem.dev";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "1G";
    };
    postgresPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Host path (e.g. a sops secret's .path) to a file containing the
        Postgres password. Only takes effect on Postgres's own first
        start (initdb sets it once from the container's env) — rotating
        this option's value afterward does NOT retroactively change a
        live cluster's password; that also needs an `ALTER USER pguser
        WITH PASSWORD ...` run against the running container. Generate
        with: openssl rand -hex 32
      '';
    };
    minioRootPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host path (e.g. a sops secret's .path) to a file containing the MinIO root password. Same first-start-only caveat as postgresPasswordFile. Generate with: openssl rand -hex 32";
    };
    jwtSecretFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host path (e.g. a sops secret's .path) to a file containing museum's jwt.secret — signs/verifies auth tokens, so a leaked or guessable value lets anyone forge them. Safe to rotate any time (just re-signs future tokens). Generate with: openssl rand -hex 32";
    };
    keyEncryptionFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Host path to a file containing museum's key.encryption — used to
        encrypt customer emails before storing them in Postgres. Must be
        base64, museum's own gen-random-keys tool format (32 random
        bytes). Generate with:
        `nix run nixpkgs#openssl -- rand -base64 32`
      '';
    };
    keyHashFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Host path to a file containing museum's key.hash. Must be
        base64, 64 random bytes (museum's gen-random-keys tool uses a
        larger key here than key.encryption). Generate with:
        `nix run nixpkgs#openssl -- rand -base64 64`
      '';
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkContainer {
        inherit config;
        name = "ente";
        inherit cfg;
        # Bundles the 15m pull timeout, nesting caps/devices, podman's own
        # registries.conf, and persistent podman image storage — see
        # factory.nix's usesPodman doc comment. Postgres + MinIO still run
        # this way; museum itself no longer does (see below).
        usesPodman = true;
        innerConfig = {
          # museum itself is a native Nix package (nix-packages' ente-museum),
          # not a podman container — ghcr.io/ente-io/server went to a bare 403
          # Forbidden (confirmed live 2026-09-24, even listing tags), and
          # ente's own compose.yaml no longer references a prebuilt image at
          # all (`build: context: .`). A source build sidesteps depending on
          # any registry's continued goodwill entirely — see
          # nix-packages/pkgs/ente-museum's own doc comment for the pin/bump
          # procedure.
          imports = [ inputs.nix-packages.nixosModules.ente-museum ];
          nixpkgs.overlays = [ inputs.nix-packages.overlays.default ];

          # Native museum process. Reaches Postgres/MinIO via localhost, which
          # needs those podman containers on host networking (same reason
          # authentik.nix's native Postgres needs its podman containers on
          # --network=host — a name-based podman-internal DNS lookup like
          # "postgres"/"minio" only resolves between containers on podman's
          # own bridge network, not from a plain host-side systemd service).
          services.ente-museum = {
            enable = true;
            db.host = "localhost";
            s3 = {
              endpoint = "localhost:3200";
              bucket = "ente";
            };
            environmentFile = "/run/ente.env";
          };

          virtualisation.oci-containers = {
            backend = "podman";
            containers = {
              postgres = {
                image = "postgres:15-alpine";
                volumes = [
                  "/var/lib/ente/postgres:/var/lib/postgresql/data"
                ];
                environment = {
                  POSTGRES_USER = "pguser";
                  POSTGRES_DB = "ente_db";
                };
                environmentFiles = [ "/run/ente.env" ];
                extraOptions = [ "--network=host" ];
              };

              minio = {
                # docker.io/minio/minio (the unqualified default registry for
                # this container per usesPodman's unqualified-search-registries)
                # started refusing anonymous pulls entirely — MinIO Inc.
                # restricted Docker Hub distribution of the community/AGPL
                # image in their 2025 licensing changes. Confirmed live
                # 2026-09-24: `docker.io/minio/minio:latest` → "requested
                # access to the resource is denied"; quay.io/minio/minio still
                # serves it, verified aarch64 manifest present (core-pi is a
                # Pi 5). Pinned to a real release tag instead of floating
                # `latest` again — quay.io's own `latest` could just as easily
                # get orphaned the same way if MinIO changes distribution
                # again; a pin at least fails loudly (image not found) instead
                # of silently drifting.
                image = "quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z";
                cmd = [
                  "server"
                  "/data"
                  "--address"
                  ":3200"
                  "--console-address"
                  ":3201"
                ];
                volumes = [
                  "/var/lib/ente/minio:/data"
                ];
                environment = {
                  MINIO_ROOT_USER = "admin";
                };
                environmentFiles = [ "/run/ente.env" ];
                extraOptions = [ "--network=host" ];
              };
            };
          };

          networking.firewall.allowedTCPPorts = [ 8080 ];

          # Consolidated: statix flags repeated top-level `systemd.*`
          # assignments (this file used to set systemd.services.<name>
          # separately at 4 different points, plus systemd.tmpfiles.rules
          # at a 5th). Functionally identical either way (Nix's dotted
          # attrpath sugar already merges same-prefix, different-leaf
          # assignments fine), just written as one block now.
          systemd = {
            services = {
              # Materialises the Postgres/MinIO/museum secrets env file
              # from sops secrets at activation instead of baking real
              # credentials into environment.etc (world-readable, lands in
              # the Nix store) — this file used to inline literal "pgpass"
              # / "password123" and the upstream jwt_secret placeholder
              # string directly into the repo. Missing *File options
              # render as an empty secret rather than falling back to
              # those old values, so the services fail closed instead of
              # silently running on a known-weak default. One shared env
              # file: podman's environmentFiles and systemd's
              # EnvironmentFile both just ignore keys they don't
              # recognise, so there's no reason to split it three ways.
              ente-env-setup = {
                description = "Materialise Ente secrets from sops files";
                before = [
                  "podman-postgres.service"
                  "podman-minio.service"
                  "ente-museum.service"
                ];
                serviceConfig.Type = "oneshot";
                script = ''
                  umask 077
                  pgpass=$(${lib.optionalString (cfg.postgresPasswordFile != null) "cat ${postgresPasswordPath}"})
                  miniopass=$(${
                    lib.optionalString (cfg.minioRootPasswordFile != null) "cat ${minioRootPasswordPath}"
                  })
                  jwt=$(${lib.optionalString (cfg.jwtSecretFile != null) "cat ${jwtSecretPath}"})
                  keyenc=$(${lib.optionalString (cfg.keyEncryptionFile != null) "cat ${keyEncryptionPath}"})
                  keyhash=$(${lib.optionalString (cfg.keyHashFile != null) "cat ${keyHashPath}"})

                  {
                    printf 'POSTGRES_PASSWORD=%s\n' "$pgpass"
                    printf 'MINIO_ROOT_PASSWORD=%s\n' "$miniopass"
                    printf 'ENTE_DB_PASSWORD=%s\n' "$pgpass"
                    printf 'ENTE_S3_B2_EU_CEN_SECRET=%s\n' "$miniopass"
                    printf 'ENTE_JWT_SECRET=%s\n' "$jwt"
                    printf 'ENTE_KEY_ENCRYPTION=%s\n' "$keyenc"
                    printf 'ENTE_KEY_HASH=%s\n' "$keyhash"
                  } > /run/ente.env
                '';
              };

              ente-museum = {
                after = [
                  "ente-env-setup.service"
                  "podman-postgres.service"
                  "podman-minio.service"
                ];
                wants = [
                  "ente-env-setup.service"
                  "podman-postgres.service"
                  "podman-minio.service"
                ];
              };

              "podman-postgres" = {
                after = [ "ente-env-setup.service" ];
                wants = [ "ente-env-setup.service" ];
              };
              "podman-minio" = {
                after = [ "ente-env-setup.service" ];
                wants = [ "ente-env-setup.service" ];
              };
            };

            tmpfiles.rules = [
              "d /var/lib/ente/postgres 0755 root root - -"
              "d /var/lib/ente/minio 0755 root root - -"
              "d /var/lib/ente/data 0755 root root - -"
            ];
          };
        };

        bindMounts = {
          "/var/lib/ente" = {
            hostPath = cfg.hostDataDir;
            isReadOnly = false;
          };
        }
        // lib.optionalAttrs (cfg.postgresPasswordFile != null) {
          ${postgresPasswordPath} = {
            hostPath = cfg.postgresPasswordFile;
            isReadOnly = true;
          };
        }
        // lib.optionalAttrs (cfg.minioRootPasswordFile != null) {
          ${minioRootPasswordPath} = {
            hostPath = cfg.minioRootPasswordFile;
            isReadOnly = true;
          };
        }
        // lib.optionalAttrs (cfg.jwtSecretFile != null) {
          ${jwtSecretPath} = {
            hostPath = cfg.jwtSecretFile;
            isReadOnly = true;
          };
        }
        // lib.optionalAttrs (cfg.keyEncryptionFile != null) {
          ${keyEncryptionPath} = {
            hostPath = cfg.keyEncryptionFile;
            isReadOnly = true;
          };
        }
        // lib.optionalAttrs (cfg.keyHashFile != null) {
          ${keyHashPath} = {
            hostPath = cfg.keyHashFile;
            isReadOnly = true;
          };
        };
      })
      {
        # Ente Auth's DB holds every (client-side-encrypted) TOTP secret —
        # small and critical → secure. MinIO objects/data → bulk (restic),
        # sized for photos should Ente Photos ever be used.
        my.backup.items = {
          ente-db = {
            tier = "secure";
            postgres = [
              {
                machine = "ente";
                podman = "postgres";
                user = "pguser";
              }
            ];
          };
          ente-objects = {
            tier = "bulk";
            paths = [
              "${cfg.hostDataDir}/minio"
              "${cfg.hostDataDir}/data"
            ];
          };
        };
      }
    ]
  );
}
