{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.langflow;
  inherit (self.lib) mkContainer;
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
      default = false;
      description = "Start the container automatically on boot.";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "langflow";
    inherit cfg;
    usesPodman = true;
    subDirs = [ "data" ];
    innerConfig = {
      virtualisation.oci-containers = {
        backend = "podman";
        containers.langflow = {
          image = "docker.io/langflowai/langflow:latest";
          ports = [ "7860:7860" ];
          environment = {
            LANGFLOW_DATABASE_URL = "sqlite:////var/lib/langflow/langflow.db";
            LANGFLOW_HOST = "0.0.0.0";
          };
          volumes = [
            "${cfg.hostDataDir}/data:/var/lib/langflow"
          ];
        };
      };

      networking.firewall.allowedTCPPorts = [ 7860 ];
    };
  });
}
