{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.qdrant;
in
{
  options.my.containers.qdrant = {
    enable = lib.mkEnableOption "Qdrant Vector Database Container";

    ip = lib.mkOption {
      type = lib.types.str;
      description = "Static IP Address (CIDR notation preferred, e.g. 10.85.46.105/24)";
    };

    hostBridge = lib.mkOption {
      type = lib.types.str;
      default = "incusbr0";
      description = "Bridge interface on the host";
    };

    hostDataDir = lib.mkOption {
      type = lib.types.str;
      description = "Absolute path on host for persistence";
    };

    hostName = lib.mkOption {
      type = lib.types.str;
      default = "qdrant";
      description = "Hostname for the container";
    };
  };

  config = lib.mkIf cfg.enable {
    containers.qdrant = {
      autoStart = true;
      privateNetwork = true;
      hostBridge = cfg.hostBridge;
      localAddress = cfg.ip;

      config =
        { ... }:
        {
          services.qdrant = {
            enable = true;
            settings = {
              service = {
                host = "0.0.0.0";
                http_port = 6333;
                grpc_port = 6334;
              };
              storage = {
                storage_path = "/var/lib/qdrant";
              };
            };
          };

          networking.firewall.allowedTCPPorts = [ 6333 6334 ];
          system.stateVersion = "25.11";
        };

      bindMounts = {
        "/var/lib/qdrant" = {
          hostPath = cfg.hostDataDir;
          isReadOnly = false;
        };
      };
    };
  };
}
