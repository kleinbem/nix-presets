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
    enableUSB = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable USB passthrough for Zigbee/Z-Wave sticks.";
    };
    enableBluetooth = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable Bluetooth passthrough.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "4G";
    };
  };

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "home-assistant";
    inherit cfg;
    inherit (cfg) enableUSB;
    additionalCapabilities = lib.optional cfg.enableBluetooth "CAP_NET_ADMIN"; # Bluetooth needs this

    innerConfig = {
      services.home-assistant = {
        enable = true;
        extraComponents = [
          "met"
          "radio_browser"
          "esphome"
          "sun"
          "weather"
          "mobile_app"
          "prometheus" # Enable metrics for Grafana
        ];

        config = {
          # Basic configuration
          homeassistant = {
            name = "Home";
            unit_system = "metric";
            time_zone = "Europe/Dublin";
            external_url = "https://hass.internal"; # Adjust based on your domain
            internal_url = "http://${cfg.ip}:8123";
          };

          # Enable the default UI and features
          default_config = { };

          frontend = {
            themes = "!include themes.yaml";
          };

          # Performance tuning for RPi
          recorder = {
            purge_keep_days = 7;
            commit_interval = 30;
          };

          http = {
            use_x_forwarded_for = true;
            trusted_proxies = [
              "10.85.46.1" # Gateway/Bridge
              "10.85.46.107" # Caddy Container
            ];
          };

          # Declarative logic (Nix-managed hooks)
          automation = "!include automations.yaml";
          script = "!include scripts.yaml";
          scene = "!include scenes.yaml";

          # Monitoring
          prometheus = {
            namespace = "hass";
          };
        };
      };

      # Ensure the themes and logic files exist or are linked
      systemd.tmpfiles.rules = [
        "f /var/lib/hass/themes.yaml 0644 hass hass - {}"
        "f /var/lib/hass/automations.yaml 0644 hass hass - {}"
        "f /var/lib/hass/scripts.yaml 0644 hass hass - {}"
        "f /var/lib/hass/scenes.yaml 0644 hass hass - {}"
      ];

      networking.firewall.allowedTCPPorts = [ 8123 ];
    };
    bindMounts = {
      "/var/lib/hass" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
      # Bluetooth support requires access to the host's dbus
      "/run/dbus" = lib.mkIf cfg.enableBluetooth {
        hostPath = "/run/dbus";
        isReadOnly = true;
      };
    };
  });
}
