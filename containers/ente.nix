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
  s3KeyIdPath = "/run/secrets/ente-s3-key-id";
  s3SecretPath = "/run/secrets/ente-s3-secret";

  useGarage = cfg.s3.backend == "garage";
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

    s3 = {
      backend = lib.mkOption {
        type = lib.types.enum [
          "minio"
          "garage"
        ];
        default = "minio";
        description = "Object store museum uses: the in-container MinIO, or an external S3 (the fleet's Garage).";
      };
      endpoint = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://s3.kleinbem.dev";
        description = "External S3 endpoint (backend = \"garage\"). Path-style URLs, TLS on.";
      };
      region = lib.mkOption {
        type = lib.types.str;
        default = "garage";
        description = "S3 region; Garage's s3_region.";
      };
      bucket = lib.mkOption {
        type = lib.types.str;
        default = "ente";
      };
      accessKeyIdFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Host path to a file with the S3 access key id (backend = \"garage\").";
      };
      secretAccessKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Host path to a file with the S3 secret access key (backend = \"garage\").";
      };
    };

    # Kept on after the Garage cutover so the copy and a rollback still have
    # their source; turn off once Garage is verified.
    minio.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run the in-container MinIO. Required when s3.backend = \"minio\".";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = useGarage || cfg.minio.enable;
            message = "my.containers.ente: s3.backend = \"minio\" needs minio.enable.";
          }
          {
            assertion =
              !useGarage
              || (
                cfg.s3.endpoint != null && cfg.s3.accessKeyIdFile != null && cfg.s3.secretAccessKeyFile != null
              );
            message = "my.containers.ente: s3.backend = \"garage\" needs s3.endpoint, s3.accessKeyIdFile and s3.secretAccessKeyFile.";
          }
        ];
      }
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
            # Pinned major: a nixpkgs default bump would refuse the existing datadir.
            # Don't downgrade museum: it won't start ("setupDatabase file does not
            # exist") if the db has migrations newer than the package's.
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
                # b2-eu-cen is museum's default hot-storage slot, whatever the
                # backend. Key id and secret come from /run/ente.env.
                s3 = {
                  # false keeps TLS on for Garage; MinIO here is plain http.
                  are_local_buckets = !useGarage;
                  use_path_style_urls = true;
                  b2-eu-cen =
                    if useGarage then
                      { inherit (cfg.s3) endpoint region bucket; }
                    else
                      {
                        endpoint = "http://localhost:3200";
                        region = "us-east-1";
                        bucket = "ente";
                      };
                };
              };
            };

            virtualisation.oci-containers = {
              backend = "podman";
              containers = {
                minio = lib.mkIf cfg.minio.enable {
                  # Neither quay.io nor Docker Hub serves MinIO anonymously any
                  # more (minio/minio is archived): only the image already in
                  # the host's store can run, so never try to pull it.
                  # no-link: not a bug to report; MinIO goes once Ente is on Garage.
                  image = "quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z";
                  pull = "never";
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
                  image = "ghcr.io/ente/web:2a48a3c309f3ab30161e783ff97a555c2f5dbe41";
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
                    s3key=${if useGarage then "$(b64 ${s3KeyIdPath})" else "admin"}
                    s3secret=${if useGarage then "$(b64 ${s3SecretPath})" else "$miniopass"}
                    ${lib.optionalString useGarage ''
                      if [ -z "$s3key" ] || [ -z "$s3secret" ]; then
                        echo "ente-env-setup: empty Garage S3 key id or secret" >&2
                        exit 1
                      fi
                    ''}

                    {
                      printf 'MINIO_ROOT_PASSWORD=%s\n' "$miniopass"
                      printf 'ENTE_S3_B2_EU_CEN_KEY=%s\n' "$s3key"
                      printf 'ENTE_S3_B2_EU_CEN_SECRET=%s\n' "$s3secret"
                      printf 'ENTE_JWT_SECRET=%s\n' "$jwt"
                      printf 'ENTE_KEY_ENCRYPTION=%s\n' "$keyenc"
                      printf 'ENTE_KEY_HASH=%s\n' "$keyhash"
                    } > /run/ente.env
                  '';
                };

                ente = {
                  after = [ "ente-env-setup.service" ] ++ lib.optional (!useGarage) "podman-minio.service";
                  wants = [ "ente-env-setup.service" ] ++ lib.optional (!useGarage) "podman-minio.service";
                  serviceConfig.EnvironmentFile = [ "-/run/ente.env" ];
                };
                "podman-minio" = lib.mkIf cfg.minio.enable {
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
        }
        // lib.optionalAttrs useGarage {
          ${s3KeyIdPath} = {
            hostPath = cfg.s3.accessKeyIdFile;
            isReadOnly = true;
          };
          ${s3SecretPath} = {
            hostPath = cfg.s3.secretAccessKeyFile;
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
