{ self, inputs }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.dashboard;

  foyerPkg =
    if inputs ? foyer && inputs.foyer ? packages then
      inputs.foyer.packages.${pkgs.system}.default
    else
      pkgs.foyer or (pkgs.writeShellScriptBin "foyer" "echo 'foyer package not provided' && exit 1");

  hasConfigFile = cfg.configFile != null;
  hasFeedDir = cfg.feedDir != null;
  configDir = "/run/foyer";
  feedDir = "/run/foyer-feed";
in
{
  imports = [ (import ../options.nix { inherit lib; }) ];

  # A bind mount, not baked in: container-factory builds the container once
  # for all hosts (ADR-002), so the fleet's service list must come from the host.
  options.my.containers.dashboard = {
    configFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path (on the deploying host) to Foyer's `config.json` (hosts, services,
        Gatus URL; see the Foyer README), bind-mounted read-only and served as
        `/config.json`. null serves the package's empty default.
      '';
    };
    feedDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/foyer-feed";
      description = ''
        Directory (on the deploying host) of JSON files that something on the
        host regenerates, bind-mounted read-only and served under `/feed/`.
        With an `attention.json` in it, `"attentionUrl": "/feed/attention.json"`
        in `config.json` fills Foyer's "Needs attention" panel. The directory
        must exist before the container starts.
      '';
    };
    # Same-origin, because Gatus sends no CORS headers and the browser would
    # block a direct call. Baked into the closure: set it where it is built.
    gatusUrl = lib.mkOption {
      # Caddy rejects an upstream with a path, a trailing slash included.
      type = lib.types.nullOr (lib.types.strMatching "https?://[^/]+");
      default = null;
      example = "http://10.85.48.140:8080";
      description = ''
        Gatus base URL (scheme, host and port, no path). Its endpoint statuses are proxied at
        `/api/v1/endpoints/statuses`, so `"gatusUrl": "/"` in `config.json`
        gives Foyer live health.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    self.lib.mkContainer {
      inherit config;
      name = "dashboard-foyer";
      inherit cfg;
      innerConfig = {
        services.caddy = {
          enable = true;
          virtualHosts.":8082" = {
            extraConfig =
              lib.optionalString hasConfigFile ''
                handle /config.json {
                  root * ${configDir}
                  header Cache-Control no-cache
                  file_server
                }
              ''
              + lib.optionalString hasFeedDir ''
                handle_path /feed/* {
                  root * ${feedDir}
                  header Cache-Control no-cache
                  file_server
                }
              ''
              + lib.optionalString (cfg.gatusUrl != null) ''
                handle /api/v1/endpoints/statuses {
                  reverse_proxy ${cfg.gatusUrl}
                }
              ''
              + ''
                handle {
                  root * ${foyerPkg}
                  try_files {path} {path}/ /200.html
                  file_server
                }
              '';
          };
        };

        networking.firewall.allowedTCPPorts = [ 8082 ];
      };

      bindMounts =
        lib.optionalAttrs hasConfigFile {
          "${configDir}/config.json" = {
            hostPath = "${cfg.configFile}";
            isReadOnly = true;
          };
        }
        // lib.optionalAttrs hasFeedDir {
          ${feedDir} = {
            hostPath = "${cfg.feedDir}";
            isReadOnly = true;
          };
        };
    }
  );
}
