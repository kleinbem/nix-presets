{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.langflow;
  mkContainer = self.lib.mkContainer;
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
  } // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer { inherit config;
    name = "langflow";
    cfg = cfg;
    innerConfig = {
      virtualisation.oci-containers.backend = "podman";
      virtualisation.podman.enable = true;

      virtualisation.oci-containers.containers.langflow = {
        image = "langflowai/langflow:latest";
        ports = [ "7860:7860" ];
        environment = {
          LANGFLOW_DATABASE_URL = "sqlite:////var/lib/langflow/langflow.db";
          LANGFLOW_HOST = "0.0.0.0";
        };
        volumes = [
          "/var/lib/langflow:/var/lib/langflow"
        ];
      };

      networking.firewall.allowedTCPPorts = [ 7860 ];
    };
    bindMounts = {
      "/var/lib/langflow" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    };
  });
}
