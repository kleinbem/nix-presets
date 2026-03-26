_:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.langfuse;
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
    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Start the container automatically on boot.";
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path on the host to a .env file containing NEXTAUTH_SECRET and SALT";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers.containers = {
      langfuse-db = {
        image = "postgres:16-alpine";
        inherit (cfg) autoStart;
        environment = {
          POSTGRES_USER = "postgres";
          POSTGRES_PASSWORD = "postgres";
          POSTGRES_DB = "langfuse";
        };
        volumes = [
          "${cfg.hostDataDir}/db:/var/lib/postgresql/data"
        ];
        extraOptions = [
          "--net=cbr0"
          "--security-opt=no-new-privileges"
        ];
      };

      langfuse = {
        image = "ghcr.io/langfuse/langfuse:latest";
        inherit (cfg) autoStart;
        ports = [ "3000:3000" ];
        environmentFiles = lib.optional (cfg.secretsFile != null) cfg.secretsFile;
        environment = {
          DATABASE_URL = "postgresql://postgres:postgres@langfuse-db:5432/langfuse";
          NEXTAUTH_URL = "http://localhost:3000";
          TELEMETRY_ENABLED = "false";
        };
        dependsOn = [ "langfuse-db" ];
        extraOptions = [
          "--net=cbr0"
          "--ip=${lib.head (lib.splitString "/" cfg.ip)}"
          "--security-opt=no-new-privileges"
        ];
      };
    };

    systemd.services.podman-langfuse = {
      after = [ "podman-network-cbr0.service" ];
      requires = [ "podman-network-cbr0.service" ];
      serviceConfig = {
        MemoryMax = lib.mkIf (cfg.memoryLimit != null) cfg.memoryLimit;
        Environment = [ "TMPDIR=/var/lib/images/podman/tmp" ];
      };
    };
    systemd.services.podman-langfuse-db = {
      after = [ "podman-network-cbr0.service" ];
      requires = [ "podman-network-cbr0.service" ];
      serviceConfig.Environment = [ "TMPDIR=/var/lib/images/podman/tmp" ];
    };
  };
}
