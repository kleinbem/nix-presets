{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.langfuse;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.langfuse = {
    enable = lib.mkEnableOption "Langfuse Telemetry Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "4G";
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path on the host to a .env file containing NEXTAUTH_SECRET and SALT";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "langfuse";
    inherit cfg;
    innerConfig = {
      # Since there is no native NixOS service for Langfuse, we use OCI containers.
      virtualisation = {
        oci-containers.backend = "podman";
        podman.enable = true;
        oci-containers.containers.langfuse = {
          image = "ghcr.io/langfuse/langfuse:latest";
          ports = [ "3000:3000" ];
          environmentFiles = [ "/run/secrets/langfuse.env" ];
          environment = {
            DATABASE_URL = "postgresql://postgres:postgres@127.0.0.1:5432/langfuse";
            NEXTAUTH_URL = "http://localhost:3000";
            TELEMETRY_ENABLED = "false";
          };
          # Wait for Postgres to be ready
          dependsOn = [ ];
        };
      };

      # Provide the required Postgres database locally within the container
      services.postgresql = {
        enable = true;
        package = pkgs.postgresql_16;
        enableTCPIP = true;
        authentication = lib.mkForce ''
          local all all trust
          host all all 127.0.0.1/32 trust
          host all all ::1/128 trust
        '';
        initialScript = pkgs.writeText "init-langfuse-db.sql" ''
          CREATE DATABASE langfuse;
          CREATE USER postgres WITH PASSWORD 'postgres';
          GRANT ALL PRIVILEGES ON DATABASE langfuse TO postgres;
          ALTER DATABASE langfuse OWNER TO postgres;
        '';
      };

      networking.firewall.allowedTCPPorts = [
        3000
        5432
      ];

      systemd.services.podman-langfuse.after = [ "postgresql.service" ];
    };
    bindMounts = {
      "/var/lib/postgresql" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    }
    // lib.optionalAttrs (cfg.secretsFile != null) {
      "/run/secrets/langfuse.env" = {
        hostPath = cfg.secretsFile;
        isReadOnly = true;
      };
    };
  });
}
