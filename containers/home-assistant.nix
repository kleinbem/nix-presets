{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.home-assistant;
  inherit (self.lib) mkContainer;
in
{
  options.my.containers.home-assistant = {
    enable = lib.mkEnableOption "Home Assistant Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/home-assistant";
    };
  };

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "home-assistant";
    inherit cfg;
    innerConfig = {
      services.home-assistant = {
        enable = true;
        extraComponents = [
          "met"
          "radio_browser"
          "esphome"
        ];
        config = {
          # Basic configuration
          homeassistant = {
            name = "Home";
            unit_system = "metric";
            time_zone = "Europe/Dublin";
          };
          frontend = { };
          http = {
            use_x_forwarded_for = true;
            trusted_proxies = [ "10.85.46.1" ]; # Gateway/Proxy
          };
        };
      };
      networking.firewall.allowedTCPPorts = [ 8123 ];
    };
    bindMounts = {
      "/var/lib/hass" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    };
  });
}
