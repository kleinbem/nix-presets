{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.qdrant;
  mkContainer = self.lib.mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.qdrant = {
    enable = lib.mkEnableOption "Qdrant Vector Database Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "2G";
    };
  } // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer { inherit config;
    name = "qdrant";
    cfg = cfg;
    innerConfig = {
      services.qdrant = {
        enable = true;
        settings = {
          service = {
            host = "0.0.0.0";
            http_port = 6333;
            grpc_port = 6334;
          };
          storage.storage_path = "/var/lib/qdrant";
        };
      };
      systemd.services.qdrant.serviceConfig = {
        User = lib.mkForce "root";
        Group = lib.mkForce "root";
        CapabilityBoundingSet = lib.mkForce [
          "CAP_CHOWN"
          "CAP_FOWNER"
          "CAP_DAC_OVERRIDE"
          "CAP_SETUID"
          "CAP_SETGID"
        ];
        SystemCallFilter = lib.mkForce [
          "@system-service"
          "@privileged"
        ];
        NoNewPrivileges = lib.mkForce false;
        DynamicUser = lib.mkForce false;
        PrivateUsers = lib.mkForce false;
      };
      networking.firewall.allowedTCPPorts = [
        6333
        6334
      ];
    };
    bindMounts = {
      "/var/lib/qdrant" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    };
  });
}
