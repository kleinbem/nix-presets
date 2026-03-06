{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.silverbullet;
  inherit (self.lib) mkContainer; # Added mkContainer definition
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.silverbullet = {
    enable = lib.mkEnableOption "SilverBullet Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "512M";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    # Changed to mkContainer
    name = "silverbullet";
    inherit cfg;
    innerConfig = {
      # Removed networking.firewall.allowedTCPPorts
      services.silverbullet = {
        # Changed to services.silverbullet
        enable = true; # Added enable
        listenAddress = "0.0.0.0"; # Added listenAddress
        listenPort = 3030;
      };
      systemd.services.silverbullet.serviceConfig = {
        User = lib.mkForce "root";
        Group = lib.mkForce "root";
      };
      networking.firewall.allowedTCPPorts = [ 3030 ];
    };
    bindMounts = {
      "/var/lib/silverbullet" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    };
  });
}
