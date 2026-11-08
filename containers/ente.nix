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
  garageRpcSecretPath = "/run/secrets/ente-garage-rpc-secret";

  useGarage = cfg.s3.backend == "garage";
  # Garage runs in this container next to museum, under hostDataDir, so it
  # shares Ente's persistence and backups and needs nothing off-host.
  garageDir = "/var/lib/ente/garage";
  garageS3Port = 3900;
  # Pinned: the bind-mounted data dir must keep its owner across closures.
  garageUid = 3900;
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
        description = "Object store museum uses: the in-container MinIO, or the in-container Garage (garage.enable).";
      };
      bucket = lib.mkOption {
        type = lib.types.str;
        default = "ente";
        description = "Garage bucket museum uses; created by ente-garage-setup.";
      };
      accessKeyIdFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Host path to a file with the Garage access key id, imported into
          Garage at start. Garage wants `GK` + 24 hex chars:
          `echo "GK$(openssl rand -hex 12)"`
        '';
      };
      secretAccessKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Host path to a file with the Garage secret key (64 hex chars: `openssl rand -hex 32`).";
      };
    };

    garage = {
      enable = lib.mkEnableOption "a single-node Garage in the container (needed before s3.backend = \"garage\", for the copy)";
      rpcSecretFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Host path to a file with Garage's rpc_secret (64 hex chars: `openssl rand -hex 32`).";
      };
      capacity = lib.mkOption {
        type = lib.types.str;
        default = "50G";
        description = "Capacity given to the node in the layout. Single node, so it only has to be non-zero; not a quota.";
      };
      memoryMax = lib.mkOption {
        type = lib.types.str;
        default = "256M";
        description = "MemoryMax for garage.service; it idles around 40 MB. The container's memoryLimit still caps the total.";
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
            assertion = !useGarage || cfg.garage.enable;
            message = "my.containers.ente: s3.backend = \"garage\" needs garage.enable.";
          }
          {
            assertion =
              !cfg.garage.enable
              || (
                cfg.garage.rpcSecretFile != null
                && cfg.s3.accessKeyIdFile != null
                && cfg.s3.secretAccessKeyFile != null
              );
            message = "my.containers.ente: garage.enable needs garage.rpcSecretFile, s3.accessKeyIdFile and s3.secretAccessKeyFile.";
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
            services = {
              postgresql.package = pkgs.postgresql_17;

              garage = lib.mkIf cfg.garage.enable {
                enable = true;
                package = pkgs.garage_2;
                environmentFile = "/run/garage.env";
                settings = {
                  metadata_dir = "${garageDir}/meta";
                  data_dir = "${garageDir}/data";
                  # sqlite: lmdb is crash-fragile on a single node.
                  db_engine = "sqlite";
                  # Consistent copy of the metadata db under meta/snapshots for restic.
                  metadata_auto_snapshot_interval = "6h";
                  replication_factor = 1;
                  # Small write buffer: core-pi is short on RAM.
                  block_ram_buffer_max = "32MiB";
                  rpc_bind_addr = "127.0.0.1:3901";
                  rpc_public_addr = "127.0.0.1:3901";
                  s3_api = {
                    s3_region = "garage";
                    api_bind_addr = "127.0.0.1:${toString garageS3Port}";
                  };
                };
              };
              ente.api = {
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
                    # Both stores are plain http on localhost.
                    are_local_buckets = true;
                    use_path_style_urls = true;
                    b2-eu-cen =
                      if useGarage then
                        {
                          endpoint = "http://localhost:${toString garageS3Port}";
                          region = "garage";
                          inherit (cfg.s3) bucket;
                        }
                      else
                        {
                          endpoint = "http://localhost:3200";
                          region = "us-east-1";
                          bucket = "ente";
                        };
                  };
                };
              };
            };

            users = lib.mkIf cfg.garage.enable {
              users.garage = {
                isSystemUser = true;
                uid = garageUid;
                group = "garage";
              };
              groups.garage.gid = garageUid;
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
                    "garage.service"
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
                    ${lib.optionalString cfg.garage.enable ''
                      printf 'GARAGE_RPC_SECRET=%s\n' "$(b64 ${garageRpcSecretPath})" > /run/garage.env
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

                ente = rec {
                  after = [
                    "ente-env-setup.service"
                    (if useGarage then "ente-garage-setup.service" else "podman-minio.service")
                  ];
                  wants = after;
                  # Don't start museum on missing or stale Garage credentials.
                  requires = lib.optionals useGarage [
                    "ente-env-setup.service"
                    "ente-garage-setup.service"
                  ];
                  serviceConfig.EnvironmentFile = [ "-/run/ente.env" ];
                };
                "podman-minio" = lib.mkIf cfg.minio.enable {
                  after = [ "ente-env-setup.service" ];
                  wants = [ "ente-env-setup.service" ];
                };

                garage = lib.mkIf cfg.garage.enable {
                  after = [ "ente-env-setup.service" ];
                  wants = [ "ente-env-setup.service" ];
                  unitConfig.RequiresMountsFor = "/var/lib/ente";
                  serviceConfig = {
                    DynamicUser = lib.mkForce false;
                    User = "garage";
                    Group = "garage";
                    MemoryMax = cfg.garage.memoryMax;
                    # Not tmpfiles: it refuses to create a garage-owned dir below
                    # the host-owned /var/lib/ente ("unsafe path transition").
                    StateDirectory = map (d: lib.removePrefix "/var/lib/" d) [
                      garageDir
                      "${garageDir}/meta"
                      "${garageDir}/data"
                    ];
                    StateDirectoryMode = "0750";
                  };
                };

                # Layout, bucket and key, idempotent on every start. The key is
                # imported from sops rather than generated, so museum and the
                # copy can use it without reading it back out of Garage.
                ente-garage-setup = lib.mkIf cfg.garage.enable {
                  description = "Create Ente's Garage layout, bucket and key";
                  after = [ "garage.service" ];
                  requires = [ "garage.service" ];
                  wantedBy = [ "multi-user.target" ];
                  serviceConfig = {
                    Type = "oneshot";
                    RemainAfterExit = true;
                    EnvironmentFile = "/run/garage.env";
                  };
                  path = [ pkgs.garage_2 ];
                  script = ''
                    for _ in $(seq 60); do garage status >/dev/null 2>&1 && break; sleep 1; done
                    node=$(garage node id -q | cut -d@ -f1)
                    if ! garage layout show | grep -q "''${node:0:16}"; then
                      garage layout assign -z dc1 -c ${cfg.garage.capacity} "$node"
                      ver=$(garage layout show | sed -n 's/.*apply --version \([0-9]*\).*/\1/p' | head -1)
                      garage layout apply --version "$ver"
                    fi
                    garage bucket info ${cfg.s3.bucket} >/dev/null 2>&1 || garage bucket create ${cfg.s3.bucket}
                    keyid=$(tr -d '[:space:]' < ${s3KeyIdPath})
                    garage key info "$keyid" >/dev/null 2>&1 \
                      || garage key import --yes -n ${cfg.s3.bucket}-key "$keyid" "$(tr -d '[:space:]' < ${s3SecretPath})"
                    garage bucket allow --read --write ${cfg.s3.bucket} --key "$keyid"
                  '';
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
        // lib.optionalAttrs cfg.garage.enable {
          ${garageRpcSecretPath} = {
            hostPath = cfg.garage.rpcSecretFile;
            isReadOnly = true;
          };
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
        # small and critical → secure. Object store (MinIO, Garage) and data
        # → bulk (restic), sized for photos should Ente Photos ever be used.
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
            ]
            ++ lib.optional cfg.garage.enable "${cfg.hostDataDir}/garage";
          };
        };
      }
    ]
  );
}
