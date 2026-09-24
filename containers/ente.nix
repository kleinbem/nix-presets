{ self }:
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
in
{
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
      description = "Host path (e.g. a sops secret's .path) to a file containing museum's credentials.jwt_secret — signs/verifies auth tokens, so a leaked or guessable value lets anyone forge them. Safe to rotate any time (just re-signs future tokens). Generate with: openssl rand -hex 32";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "ente";
    inherit cfg;
    # Bundles the 15m pull timeout, nesting caps/devices, podman's own
    # registries.conf, and persistent podman image storage — see
    # factory.nix's usesPodman doc comment. This container pulls THREE
    # images (postgres, minio, museum) into the same 2G ephemeral root —
    # closest of the four podman-in-nspawn presets to tripping the
    # "no space left on device" crash loop authentik.nix hit.
    usesPodman = true;
    innerConfig = {
      # Materialise museum.yaml + the Postgres/MinIO env file from sops
      # secrets at activation instead of baking real credentials into
      # environment.etc (world-readable, lands in the Nix store) — this
      # file used to inline literal "pgpass" / "password123" and the
      # upstream jwt_secret placeholder string directly into the repo.
      # Missing *File options render as an empty secret rather than
      # falling back to those old values, so the services fail closed
      # instead of silently running on a known-weak default.
      systemd.services.ente-env-setup = {
        description = "Materialise Ente secrets from sops files";
        before = [
          "podman-postgres.service"
          "podman-minio.service"
          "podman-museum.service"
        ];
        serviceConfig.Type = "oneshot";
        script = ''
          umask 077
          pgpass=$(${lib.optionalString (cfg.postgresPasswordFile != null) "cat ${postgresPasswordPath}"})
          miniopass=$(${lib.optionalString (cfg.minioRootPasswordFile != null) "cat ${minioRootPasswordPath}"})
          jwt=$(${lib.optionalString (cfg.jwtSecretFile != null) "cat ${jwtSecretPath}"})

          {
            printf 'POSTGRES_PASSWORD=%s\n' "$pgpass"
            printf 'MINIO_ROOT_PASSWORD=%s\n' "$miniopass"
          } > /run/ente.env

          cat > /run/museum.yaml <<CFGEOF
          db:
            host: postgres
            port: 5432
            user: pguser
            password: $pgpass
            database: ente_db
          s3:
            endpoint: minio:3200
            access_key: admin
            secret_key: $miniopass
            bucket: ente
            region: us-east-1
            secure: false
          credentials:
            jwt_secret: "$jwt"
          CFGEOF
        '';
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
          };

          museum = {
            image = "ghcr.io/ente-io/server:latest";
            ports = [ "8080:8080" ];
            dependsOn = [
              "postgres"
              "minio"
            ];
            volumes = [
              "/var/lib/ente/data:/data"
              "/run/museum.yaml:/museum.yaml:ro"
            ];
            environment = {
              ENTE_API_ORIGIN = "https://${cfg.domain}";
            };
          };
        };
      };

      systemd.services."podman-postgres" = {
        after = [ "ente-env-setup.service" ];
        wants = [ "ente-env-setup.service" ];
      };
      systemd.services."podman-minio" = {
        after = [ "ente-env-setup.service" ];
        wants = [ "ente-env-setup.service" ];
      };
      systemd.services."podman-museum" = {
        after = [ "ente-env-setup.service" ];
        wants = [ "ente-env-setup.service" ];
      };

      networking.firewall.allowedTCPPorts = [ 8080 ];

      systemd.tmpfiles.rules = [
        "d /var/lib/ente/postgres 0755 root root - -"
        "d /var/lib/ente/minio 0755 root root - -"
        "d /var/lib/ente/data 0755 root root - -"
      ];
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
    };
  });
}
