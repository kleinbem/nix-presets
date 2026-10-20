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
    lanUrl = lib.mkOption {
      type = lib.types.str;
      default = "10.0.0.21:8123";
      description = "host:port where LAN clients reach Home Assistant (the host's DNAT to the container). Used for internal_url and the embedded host-service dashboards.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkContainer {
        inherit config;
        name = "home-assistant";
        inherit cfg;
        inherit (cfg) enableUSB;
        # habluetooth needs both to manage/recover the adapter over bluez;
        # with NET_ADMIN alone it logs "Missing required permissions for
        # Bluetooth management" and can't reset a wedged adapter.
        additionalCapabilities = lib.optionals cfg.enableBluetooth [
          "CAP_NET_ADMIN"
          "CAP_NET_RAW"
        ];

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
              customComponents = with pkgs.home-assistant-custom-components; [
                alarmo
                # "Sign in with Authentik" next to the local login (OIDC, public
                # client + PKCE, no secret). The Authentik side is
                # nix/infra/authentik.tf's oidc_apps.home-assistant; config below.
                auth_oidc
                # In-process HA-MCP server (87 tools) for Claude Code & co. UI-configured
                # (admin token + access mode); the client side is modules.mcp.homeAssistant
                # in ../mcp.nix.
                ha_mcp_tools
              ];
              customLovelaceModules = with pkgs.home-assistant-custom-lovelace-modules; [ button-card ];

              config = {
                # Basic configuration
                homeassistant = {
                  name = "Home";
                  unit_system = "metric";
                  time_zone = "Europe/Dublin";
                  external_url = "https://hass.kleinbem.dev";
                  # NOT the container address: internal_url is what the companion
                  # app and other LAN clients are told to use, and cfg.ip lives on
                  # the host's private bridge. The host DNATs its LAN port 8123 to
                  # the container (hosts/hass-pi/default.nix).
                  internal_url = "http://${cfg.lanUrl}";
                };

                # Enable the default UI and features
                default_config = { };

                frontend = {
                  themes = "!include themes.yaml";
                };

                # Sidebar entries for the host-side services (ESPHome device builder,
                # Node-RED): HA Core on NixOS has no Supervisor add-on panels, and
                # panel_iframe is gone from Home Assistant (removed before 2026.10), so
                # these are YAML-mode dashboards with one iframe card each. The YAML
                # files are store paths linked in by the tmpfiles rules below.
                # Dashboard keys must contain a hyphen.
                lovelace = {
                  mode = "storage";
                  dashboards = {
                    esphome-builder = {
                      mode = "yaml";
                      title = "ESPHome Builder";
                      icon = "mdi:chip";
                      show_in_sidebar = true;
                      require_admin = true;
                      filename = "dashboards/esphome-builder.yaml";
                    };
                    node-red = {
                      mode = "yaml";
                      title = "Node-RED";
                      icon = "mdi:sitemap";
                      show_in_sidebar = true;
                      require_admin = true;
                      filename = "dashboards/node-red.yaml";
                    };
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
                  ];
                };

                # Declarative logic (Nix-managed hooks)
                automation = "!include automations.yaml";
                script = "!include scripts.yaml";
                scene = "!include scenes.yaml";

                # Authentik as OIDC login (custom component auth_oidc above).
                # Public client, so nothing secret lives here. Users come in as
                # "<authentik username>" and get HA's admin role via the staff
                # group; the local owner account stays as break-glass login.
                auth_oidc = {
                  client_id = "home-assistant";
                  discovery_url = "https://auth.kleinbem.dev/application/o/home-assistant/.well-known/openid-configuration";
                  display_name = "Authentik";
                  # Authentik's profile scope already carries `groups`; asking for a
                  # separate `groups` scope it doesn't define would be rejected.
                  features.include_groups_scope = false;
                  roles.admin = "staff";
                };

                # Monitoring
                prometheus = {
                  namespace = "hass";
                };
              };
            };

            # Ensure the themes and logic files exist or are linked
            systemd.tmpfiles.rules =
              let
                iframeDashboard =
                  name: title: url:
                  (pkgs.formats.yaml { }).generate "${name}.yaml" {
                    inherit title;
                    views = [
                      {
                        inherit title;
                        panel = true;
                        cards = [
                          {
                            type = "iframe";
                            inherit url;
                            aspect_ratio = "100%";
                          }
                        ];
                      }
                    ];
                  };
                lanHost = builtins.head (lib.splitString ":" cfg.lanUrl);
              in
              [
                "d /var/lib/hass/dashboards 0755 hass hass -"
                "L+ /var/lib/hass/dashboards/esphome-builder.yaml - - - - ${
                  iframeDashboard "esphome-builder" "ESPHome Builder" "http://${lanHost}:6052"
                }"
                "L+ /var/lib/hass/dashboards/node-red.yaml - - - - ${
                  iframeDashboard "node-red" "Node-RED" "http://${lanHost}:1880"
                }"
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
