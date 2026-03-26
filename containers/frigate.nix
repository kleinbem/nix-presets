{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.frigate;
  inherit (self.lib) mkContainer;
in
{
  options.my.containers.frigate = {
    enable = lib.mkEnableOption "Frigate Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/frigate";
    };
    mediaDir = lib.mkOption {
      type = lib.types.str;
      description = "Path to the dedicated Frigate storage SSD.";
      default = "/mnt/frigate";
    };
    enableGPU = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    enableHailo = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
  };

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "frigate";
    cfg = cfg // {
      extraAllowedDevices = lib.optionals cfg.enableHailo [
        {
          node = "/dev/hailo0";
          modifier = "rw";
        }
      ];
    };
    innerConfig = {
      services.frigate = {
        enable = false;
        hostname = "frigate";
        vaapiDriver = if cfg.enableGPU then "nvidia" else null;
        settings.cameras = { };
      };
      networking.firewall.allowedTCPPorts = [
        5000
        8554
        8555
      ];
      networking.firewall.allowedUDPPorts = [ 8555 ];
    };
    bindMounts = {
      "/var/lib/frigate" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
      "/media/frigate" = {
        hostPath = cfg.mediaDir;
        isReadOnly = false;
      };
    };
  });
}
