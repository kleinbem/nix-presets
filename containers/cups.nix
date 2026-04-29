{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.cups;
  inherit (self.lib) mkContainer;
in
{
  options.my.containers.cups = {
    enable = lib.mkEnableOption "CUPS Print Server Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "1G";
    };
  };

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "cups";
    inherit cfg;

    # Needs to be able to scan for USB printers
    enableUSB = true;

    innerConfig = _: {
      services.printing = {
        enable = true;
        # Share printers with the local network
        listenAddresses = [ "*:631" ];
        allowFrom = [ "all" ];
        browsing = true;
        defaultShared = true;
        stateless = true; # Store config in /etc
      };

      # Ensure Avahi works for mDNS printer discovery
      services.avahi = {
        enable = true;
        nssmdns4 = true;
        publish = {
          enable = true;
          userServices = true;
        };
      };

      networking.firewall.allowedTCPPorts = [ 631 ];
      networking.firewall.allowedUDPPorts = [
        631
        5353
      ];
    };

    bindMounts = {
      "/var/lib/cups" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    };
  });
}
