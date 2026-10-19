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
  imports = [ ../nixosModules/backup-engine ];

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

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkContainer {
        inherit config;
        name = "home-assistant";
        inherit cfg;
        inherit (cfg) enableUSB;
        additionalCapabilities = lib.optional cfg.enableBluetooth "CAP_NET_ADMIN"; # Bluetooth needs this

        innerConfig =
          { pkgs, ... }:
          {
            # Upstream workaround: paho-mqtt 2.1.0's test suite fails under Python 3.14
            # (callback-registration assertion, on_unsubscribe/on_disconnect), which
            # breaks the whole home-assistant closure — and thus the container-factory
            # aarch64 build — from source. paho-mqtt is a pure transitive dep here, so
            # skip its check phase until nixpkgs ships the fix. Scoped to this
            # container's nixpkgs only. REMOVE once paho-mqtt builds green upstream.
            nixpkgs.overlays = [
              (_final: prev: {
                pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
                  (_pyfinal: pyprev: {
                    paho-mqtt = pyprev.paho-mqtt.overridePythonAttrs (_: {
                      doCheck = false;
                    });
                    # Home Assistant (2026.10, and still dev) pins
                    # pywizlight==0.6.3; nixpkgs moved the package to 0.6.6,
                    # whose multi-zone API turns `bulb.state` into a list and
                    # breaks every WiZ entity ("'list' object has no attribute
                    # 'get_brightness'", seen in the restore dry run). HA closed
                    # its own bump PRs (home-assistant/core#186933) until
                    # dual-zone support lands, so pin the library back to what HA
                    # expects. REMOVE once HA's wiz manifest requires >= 0.6.6.
                    pywizlight = pyprev.pywizlight.overridePythonAttrs (_: {
                      version = "0.6.3";
                      src = prev.fetchFromGitHub {
                        owner = "sbidy";
                        repo = "pywizlight";
                        tag = "v0.6.3";
                        hash = "sha256-rCoWdqvFLSLNBAHeFJ6f9kZpIg4WyE8VJLpmsYl+gJM=";
                      };
                    });
                  })
                ];
              })
            ];

            services.home-assistant = {
              enable = true;
              # Every integration the HAOS backup (MigrateToNixOS, 2026-06-04)
              # had configured, so the restored .storage config entries find
              # their python deps baked into the closure — HA Core on NixOS
              # can't pip-install at runtime. Keep in sync with
              # .storage/core.config_entries on hass-pi.
              extraComponents = [
                "met"
                "radio_browser"
                "esphome"
                "sun"
                "weather"
                "mobile_app"
                "prometheus" # Enable metrics for Grafana
                # restored from the HAOS backup
                "androidtv_remote"
                "backup"
                "bluetooth"
                "bthome"
                "cast"
                "go2rtc"
                "google_translate"
                "lifx"
                "matter"
                "netgear"
                "openai_conversation"
                "oralb"
                "renault"
                "shelly"
                "shopping_list"
                "upnp"
                "wiz"
                # Thread radio (SkyConnect) — deps only; the dongle + OTBR
                # (services.openthread-border-router) still have to move over.
                "thread"
                "otbr"
                "homeassistant_sky_connect"
                # Discovery flows HA tried to load during the restore dry run
                # (ssdp found a QNAP switch, dhcp a Google device); without the
                # libs each one logs an import error on every start.
                "nest"
                "qnap_qsw"
              ];

              # Was HACS-installed on HAOS; nixpkgs packages both, so HACS
              # itself is dropped. Lovelace resource path for button-card:
              # /local/nixos-lovelace-modules/button-card.js
              customComponents = with pkgs.home-assistant-custom-components; [ alarmo ];
              customLovelaceModules = with pkgs.home-assistant-custom-lovelace-modules; [ button-card ];

              config = {
                # Basic configuration
                homeassistant = {
                  name = "Home";
                  unit_system = "metric";
                  time_zone = "Europe/Dublin";
                  external_url = "https://hass.kleinbem.dev";
                  internal_url = "http://${cfg.ip}:8123";
                };

                # Enable the default UI and features
                default_config = { };

                frontend = {
                  themes = "!include themes.yaml";
                };

                # ESPHome device builder (dashboard for authoring/compiling/
                # flashing device configs) isn't a Supervisor add-on here — this
                # host runs Home Assistant Core natively via NixOS, not HAOS, so
                # the usual embedded-add-on sidebar panel isn't available.
                # panel_iframe gets the same "feels integrated" result: a sidebar
                # tab that just embeds the standalone dashboard's own URL. Only
                # one host (hass-pi) has ever consumed this preset, so the LAN IP
                # is hardcoded here rather than plumbed through as a cfg option —
                # same pragmatic call already made for e.g. `trusted_proxies`
                # above. Revisit if a second host ever needs a different URL.
                panel_iframe = {
                  esphome_builder = {
                    title = "ESPHome Builder";
                    icon = "mdi:chip";
                    url = "http://10.0.0.21:6052";
                    require_admin = true;
                  };
                };

                # Performance tuning for RPi
                recorder = {
                  purge_keep_days = 7;
                  commit_interval = 30;
                };

                http = {
                  use_x_forwarded_for = true;
                  trusted_proxies = [
                    "127.0.0.1"
                    "::1"
                    "10.85.49.1" # Hass-Pi Gateway/Bridge
                    "10.85.48.107" # Caddy Container (Core-Pi)
                    "10.0.0.22" # Core-Pi LAN
                    "100.117.146.201" # Core-Pi NetBird Mesh IP
                    "10.85.46.1" # Legacy Gateway/Bridge
                    "10.85.46.107" # Legacy Caddy
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
      })
      {
        my.backup.items.home-assistant = {
          tier = "bulk";
          paths = [ cfg.hostDataDir ];
        };
      }
    ]
  );
}
