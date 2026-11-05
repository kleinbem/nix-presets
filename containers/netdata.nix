{ self }:
{
  config,
  lib,
  myInventory,
  ...
}:
let
  cfg = config.my.containers.netdata;
  inherit (self.lib) mkContainer;
in
{
  options.my.containers.netdata = {
    enable = lib.mkEnableOption "Netdata NixOS-Native Container";
    ip = lib.mkOption {
      type = lib.types.str;
      default = myInventory.network.nodes.netdata.ip or "10.85.46.122";
    };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/images/netdata";
    };
  }
  // import ../lib/tls-options.nix { inherit lib; };

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "netdata";
    inherit cfg;
    innerConfig = {
      services.netdata = {
        enable = true;
        config = {
          global = {
            "history main" = "86400";
            "memory mode" = "dbengine";
          };
        };
      };

      networking.firewall.allowedTCPPorts = [ 19999 ];
    };

    # Bind-mount history and config to host for persistence
    bindMounts = {
      "/var/lib/netdata" = {
        hostPath = "${cfg.hostDataDir}/lib";
        isReadOnly = false;
      };
      "/var/cache/netdata" = {
        hostPath = "${cfg.hostDataDir}/cache";
        isReadOnly = false;
      };
      # Netdata needs host access to monitor the system
      "/host/proc" = {
        hostPath = "/proc";
        isReadOnly = true;
      };
      "/host/sys" = {
        hostPath = "/sys";
        isReadOnly = true;
      };
      "/host/etc/os-release" = {
        hostPath = "/etc/os-release";
        isReadOnly = true;
      };
    };
  });
}
