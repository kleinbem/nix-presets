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
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host path to an env file with LANGFLOW_SUPERUSER, LANGFLOW_SUPERUSER_PASSWORD and LANGFLOW_SECRET_KEY. Required: auto-login is off.";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = cfg.secretsFile != null;
            message = "my.containers.langflow.secretsFile is required: it holds the superuser login, since auto-login is off.";
          }
        ];
      }
      (mkContainer {
        inherit config;
        name = "langflow";
        inherit cfg;
        inherit (cfg) secretsFile;
        usesPodman = true;
        subDirs = [ "data" ];
        innerConfig = {
          virtualisation.oci-containers = {
            backend = "podman";
            containers.langflow = {
              image = "docker.io/langflowai/langflow:1.13.2"; # image-bump: semver
              ports = [ "7860:7860" ];
              environment = {
                LANGFLOW_DATABASE_URL = "sqlite:////var/lib/langflow/langflow.db";
                LANGFLOW_HOST = "0.0.0.0";
                LANGFLOW_AUTO_LOGIN = "false";
              };
              environmentFiles = lib.optional (cfg.secretsFile != null) "/run/secrets/langflow.env";
              volumes = [
                "${cfg.hostDataDir}/data:/var/lib/langflow"
              ];
            };
          };

          networking.firewall.allowedTCPPorts = [ 7860 ];
        };
      })
    ]
  );
}
