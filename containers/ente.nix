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
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "ente";
    inherit cfg;
    enableNesting = true; # Required for OCI-in-LXC
    innerConfig = {
      virtualisation.podman = {
        enable = true;
        dockerCompat = true;
      };

      environment.etc."museum.yaml".text = ''
        db:
          host: postgres
          port: 5432
          user: pguser
          password: pgpass
          database: ente_db
        s3:
          endpoint: minio:3200
          access_key: admin
          secret_key: password123
          bucket: ente
          region: us-east-1
          secure: false
        credentials:
          # JWT secret used for signing tokens (change this!)
          jwt_secret: "change_me_to_a_random_string_32_chars"
      '';

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
              POSTGRES_PASSWORD = "pgpass";
              POSTGRES_DB = "ente_db";
            };
          };

          minio = {
            image = "minio/minio";
            cmd = [ "server" "/data" "--address" ":3200" "--console-address" ":3201" ];
            volumes = [
              "/var/lib/ente/minio:/data"
            ];
            environment = {
              MINIO_ROOT_USER = "admin";
              MINIO_ROOT_PASSWORD = "password123";
            };
          };

          museum = {
            image = "ghcr.io/ente-io/server:latest";
            ports = [ "8080:8080" ];
            dependsOn = [ "postgres" "minio" ];
            volumes = [
              "/var/lib/ente/data:/data"
              "/etc/museum.yaml:/museum.yaml:ro"
            ];
            environment = {
              ENTE_API_ORIGIN = "https://${cfg.domain}";
            };
          };
        };
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
    };
  });
}
