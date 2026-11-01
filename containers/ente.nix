{ self, ... }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.ente;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };

  # In-container paths the *File options are bind-mounted to; the env-setup
  # script reads them into /run/ente.env.
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
    # No default: a stale default hostname silently breaks museum's WebAuthn origin.
    domain = lib.mkOption {
      type = lib.types.str;
      description = "Public hostname of the museum API (e.g. 2fa.example.com); also its WebAuthn RP ID.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "1G";
    };
    minioRootPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host path (e.g. a sops secret's .path) to a file containing the MinIO root password. Only takes effect on MinIO's first boot — rotating it later also needs `mc admin user` against the live instance. Generate with: openssl rand -hex 32";
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
        # For MinIO and the web app; museum and Postgres are native.
        usesPodman = true;
        # Must pre-exist on the host before nspawn starts — see factory.nix's
        # subDirs doc comment.
        subDirs = [ "postgresql" ];
        innerConfig =
          { pkgs, ... }:
          {
            # museum reaches MinIO on localhost, so MinIO runs with host networking.
            # enableLocalDB gives native Postgres with peer auth (no DB password).
            # Pinned major: a nixpkgs default bump would refuse the existing datadir.
            # Before downgrading museum: it refuses to start ("setupDatabase file
            # does not exist") if the db has migrations newer than the package's.
            services.postgresql.package = pkgs.postgresql_17;

            services.ente.api = {
              enable = true;
              enableLocalDB = true;
              inherit (cfg) domain;
              settings = {
                # The module only sets webauthn from services.ente.web, which
                # isn't used here; without it museum panics ("the field 'RPID'
                # must be configured").
                webauthn = {
                  rpid = "kleinbem.dev";
                  rporigins = [
                    "https://${cfg.domain}"
                    "https://2fa.kleinbem.dev"
                  ];
                };
                s3 = {
                  are_local_buckets = true;
                  use_path_style_urls = true;
                  b2-eu-cen = {
                    endpoint = "http://localhost:3200";
                    region = "us-east-1";
                    bucket = "ente";
                    key = "admin";
                  };
                };
              };
            };

            virtualisation.oci-containers = {
              backend = "podman";
              containers = {
                minio = {
                  # Docker Hub no longer serves MinIO anonymously; quay.io does
                  # (aarch64 too). Pinned so a distribution change fails loudly.
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
                web = {
                  # Serves Ente SPAs via internal nginx; port 3003 is the Auth web app.
                  # On container boot, entrypoint replaces ENTE_API_ORIGIN_PLACEHOLDER
                  # in all bundles with ENTE_API_ORIGIN. Supports amd64 + arm64.
                  image = "ghcr.io/ente/web:b4d22996c85e8080b487db1475f98487b9b10840";
                  environment = {
                    ENTE_API_ORIGIN = "https://${cfg.domain}";
                  };
                  extraOptions = [ "--network=host" ];
                };
              };
            };

            networking.firewall.allowedTCPPorts = [
              8080
              3003
            ];

            systemd = {
              services = {
                # Builds the secrets env file at runtime so nothing lands in the
                # Nix store. A missing *File renders as an empty value, so
                # services fail closed. One file serves MinIO and museum.
                ente-env-setup = {
                  description = "Materialise Ente secrets from sops files";
                  before = [
                    "podman-minio.service"
                    "ente.service"
                  ];
                  serviceConfig.Type = "oneshot";
                  script = ''
                    umask 077
                    miniopass=$(${
                      lib.optionalString (cfg.minioRootPasswordFile != null) "cat ${minioRootPasswordPath}"
                    })
                    # Strip all whitespace: `openssl rand -base64 64` wraps lines,
                    # and museum's strict decoder crash-loops on the newline.
                    b64() { tr -d '[:space:]' < "$1"; }
                    jwt=$(${lib.optionalString (cfg.jwtSecretFile != null) "b64 ${jwtSecretPath}"})
                    keyenc=$(${lib.optionalString (cfg.keyEncryptionFile != null) "b64 ${keyEncryptionPath}"})
                    keyhash=$(${lib.optionalString (cfg.keyHashFile != null) "b64 ${keyHashPath}"})

                    {
                      printf 'MINIO_ROOT_PASSWORD=%s\n' "$miniopass"
                      printf 'ENTE_S3_B2_EU_CEN_SECRET=%s\n' "$miniopass"
                      printf 'ENTE_JWT_SECRET=%s\n' "$jwt"
                      printf 'ENTE_KEY_ENCRYPTION=%s\n' "$keyenc"
                      printf 'ENTE_KEY_HASH=%s\n' "$keyhash"
                    } > /run/ente.env
                  '';
                };

                ente = {
                  after = [
                    "ente-env-setup.service"
                    "podman-minio.service"
                  ];
                  wants = [
                    "ente-env-setup.service"
                    "podman-minio.service"
                  ];
                  serviceConfig.EnvironmentFile = [ "-/run/ente.env" ];
                };
                "podman-minio" = {
                  after = [ "ente-env-setup.service" ];
                  wants = [ "ente-env-setup.service" ];
                };
              };

              tmpfiles.rules = [
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
          # postgres has a static NixOS uid, so ownership survives rebuilt closures.
          "/var/lib/postgresql" = {
            hostPath = "${cfg.hostDataDir}/postgresql";
            isReadOnly = false;
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
            postgres = [ { machine = "ente"; } ];
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
