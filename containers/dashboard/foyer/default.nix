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
  configDir = "/run/foyer";
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
    # Same-origin, because Gatus sends no CORS headers and the browser would
    # block a direct call. Baked into the closure: set it where it is built.
    gatusUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "http://10.85.48.140:8080";
      description = ''
        Gatus base URL. Its endpoint statuses are proxied at
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

      bindMounts = lib.optionalAttrs hasConfigFile {
        "${configDir}/config.json" = {
          hostPath = "${cfg.configFile}";
          isReadOnly = true;
        };
      };
    }
  );
}
