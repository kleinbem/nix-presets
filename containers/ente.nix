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

  # Fixed in-container paths the env-setup script writes to and reads
  # from — the *File options below are host-side sops paths and only
  # reach the container via the bindMounts further down (same pattern as
  # authentik.nix).
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
    # No default: the old "auth.kleinbem.dev" one went stale when Authentik
    # took that hostname (ente moved to 2fa.kleinbem.dev, 2026-09-21) and
    # silently baked the wrong origin into museum's WebAuthn config.
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
        # Bundles the 15m pull timeout, nesting caps/devices, podman's own
        # registries.conf, and persistent podman image storage — see
        # factory.nix's usesPodman doc comment. Only MinIO still runs this
        # way; museum and Postgres are native (see below).
        usesPodman = true;
        # Must pre-exist on the host before nspawn starts — see factory.nix's
        # subDirs doc comment.
        subDirs = [ "postgresql" ];
        innerConfig =
          { pkgs, ... }:
          {
            # Native museum process from nixpkgs (services.ente.api / pkgs.museum).
            # Reaches MinIO via localhost, which needs that podman container on
            # host networking (same reason authentik.nix's podman containers
            # use --network=host).
            #
            # Postgres: upstream's enableLocalDB — native services.postgresql,
            # role+db `ente`, museum connects over /run/postgresql with peer
            # auth, so there's no DB password at all. Until 2026-10 this was a
            # podman postgres:15-alpine image (pguser/ente_db, password auth),
            # the only fleet Postgres not on the native module. The major
            # version is pinned: an unpinned default changes under a nixpkgs
            # bump and Postgres then refuses to start on the old datadir.
            #
            # Migrated 2026-10-02 as a fresh db (the old one had no users).
            # Trap for any future museum package swap: museum refuses to start
            # ("setupDatabase file does not exist") when the db's
            # schema_migrations version is newer than the highest file in the
            # package's share/museum/migrations — check before downgrading.
            services.postgresql.package = pkgs.postgresql_17;

            services.ente.api = {
              enable = true;
              enableLocalDB = true;
              inherit (cfg) domain;
              settings = {
                # Upstream only sets webauthn from services.ente.web's
                # accounts domain; without the web app it stays empty and
                # museum panics on start ("the field 'RPID' must be
                # configured"). Its generated local.yaml replaces museum's
                # bundled one wholesale, so the bundled localhost defaults
                # don't apply either.
                webauthn = {
                  rpid = cfg.domain;
                  rporigins = [ "https://${cfg.domain}" ];
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
                # Materialises the MinIO/museum secrets env file
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
                    "podman-minio.service"
                    "ente.service"
                  ];
                  serviceConfig.Type = "oneshot";
                  script = ''
                    umask 077
                    miniopass=$(${
                      lib.optionalString (cfg.minioRootPasswordFile != null) "cat ${minioRootPasswordPath}"
                    })
                    # base64 values: strip ALL whitespace, not just the trailing
                    # newline $(cat) drops. `openssl rand -base64 64` wraps at 64
                    # chars, and the stored ente_key_hash kept that wrap — museum's
                    # strict decoder then crash-looped ("Could not decode
                    # email-hash-key: illegal base64 data at input byte 64", core-pi
                    # 2026-09-26, ~940 restarts). Base64 never contains whitespace.
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
          # Postgres — static NixOS system uid, ownership stays consistent
          # across independently-built container closures (same as
          # authentik.nix/paperless.nix).
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
