_:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.langflow;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.langflow = {
    enable = lib.mkEnableOption "Langflow Visual AI Designer Container";
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
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers.containers.langflow = {
      image = "docker.io/langflowai/langflow:latest";
      inherit (cfg) autoStart;
      ports = [ "7860:7860" ];
      environment = {
        LANGFLOW_DATABASE_URL = "sqlite:////var/lib/langflow/langflow.db";
        LANGFLOW_HOST = "0.0.0.0";
      };
      volumes = [
        "${cfg.hostDataDir}:/var/lib/langflow"
      ];
      extraOptions = [
        "--network=cbr0"
        "--ip=${lib.head (lib.splitString "/" cfg.ip)}"
        "--security-opt=no-new-privileges"
      ];
    };

    systemd.services.podman-langflow = {
      after = [ "podman-network-cbr0.service" ];
      requires = [ "podman-network-cbr0.service" ];
      serviceConfig = {
        MemoryMax = lib.mkIf (cfg.memoryLimit != null) cfg.memoryLimit;
        Environment = [ "TMPDIR=/var/lib/images/podman/tmp" ];
      };
    };
  };
}
