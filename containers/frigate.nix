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
      default = false;
    };
    detector = lib.mkOption {
      type = lib.types.enum [
        "cpu"
        "hailo"
        "tensorrt"
      ];
      default = "cpu";
    };
    innerConfig = lib.mkOption {
      type = lib.types.deferredModule;
      default = { };
      description = "Extra NixOS configuration to inject into the container.";
    };
  };

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "frigate";
    inherit (cfg) enableGPU;
    cfg = cfg // {
      extraAllowedDevices = lib.optionals (cfg.detector == "hailo") [
        {
          node = "/dev/hailo0";
          modifier = "rw";
        }
      ];
    };
    innerConfig = {
      imports = [
        {
          services.frigate = {
            enable = true;
            hostname = "frigate";
            vaapiDriver = if cfg.enableGPU then "nvidia" else null;
            settings = {
              cameras = { };
              detectors = {
                main = {
                  type =
                    if cfg.detector == "tensorrt" then
                      "tensorrt"
                    else if cfg.detector == "hailo" then
                      "hailo"
                    else
                      "cpu";
                  device = if cfg.detector == "tensorrt" then "0" else null;
                };
              };
            };
          };
          networking.firewall.allowedTCPPorts = [
            5000
            8554
            8555
          ];
          networking.firewall.allowedUDPPorts = [ 8555 ];
        }
        cfg.innerConfig
      ];
    };
    bindMounts = {
      "/var/lib/frigate" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
      "/var/lib/frigate/cache" = {
        hostPath = "/var/lib/frigate/cache";
        isReadOnly = false;
      };
      "/media/frigate" = {
        hostPath = cfg.mediaDir;
        isReadOnly = false;
      };
    };
  });
}
