{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.gatus;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };

  hasEndpointsFile = cfg.endpointsFile != null;

  # gatus merges every *.yaml/*.yml file under GATUS_CONFIG_PATH when it's a
  # directory (maps deep-merged, arrays like `endpoints` appended) — see
  # https://github.com/TwiN/gatus#loading-configuration-from-a-directory.
  # That's what lets the portable base file (built into this container's
  # closure by container-factory) and the host's real endpoints file (bind-
  # mounted at runtime) live side by side without either baking the other
  # in. Numeric prefixes are just for readability; merge order doesn't
  # matter for array-append.
  configDir = "/run/gatus/conf.d";
  endpointsPath = "${configDir}/10-endpoints.yaml";

  baseConfig = (pkgs.formats.yaml { }).generate "gatus-base.yaml" {
    web.port = cfg.port;
    ui.title = "kleinbem Status";
  };
in
{
  options.my.containers.gatus = {
    enable = lib.mkEnableOption "Gatus status page / uptime monitor container";
    ip = lib.mkOption { type = lib.types.str; };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Gatus web UI port inside the container (Caddy reverse-proxies to it).";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "128M";
    };
    # Host-level bind mount, same convention as vaultwarden's
    # adminTokenFile: a fixed in-container path that the deploying host
    # points at real content, because container-factory builds this
    # container's closure once, centrally (ADR-002) — the fleet-specific
    # endpoint list can't be baked in here without losing that portability.
    # Not a secret, but the same "host-specific value, centrally-built
    # container" problem, so it gets the same fix.
    endpointsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path (on the deploying host) to a YAML file containing an
        `endpoints:` list (see https://gatus.io/docs#endpoints), bind-
        mounted read-only into the container and merged with the portable
        base config. null ⇒ gatus starts with zero endpoints, which gatus
        itself refuses to run with — set this on the deploying host, not
        here (this preset stays portable).
      '';
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "gatus";
    inherit cfg;
    innerConfig = {
      services.gatus = {
        enable = true;
        configFile = configDir;
      };

      # Materialise the portable base config into the same directory the
      # host's endpoints file is bind-mounted into (a plain /run path, not
      # /etc, so this doesn't have to race NixOS's own etc-activation).
      systemd.services = {
        gatus-config-setup = {
          description = "Materialise gatus base config for GATUS_CONFIG_PATH merge";
          wantedBy = [ "gatus.service" ];
          before = [ "gatus.service" ];
          serviceConfig.Type = "oneshot";
          script = ''
            mkdir -p ${configDir}
            ln -sf ${baseConfig} ${configDir}/00-base.yaml
          '';
        };
        gatus = {
          after = [ "gatus-config-setup.service" ];
          wants = [ "gatus-config-setup.service" ];
        };
      };

      # In-memory storage only — no bind-mounted data dir. Same call
      # ntfy.nix makes for its message cache: a container rebuild resets
      # uptime history, which is fine for a personal status page and avoids
      # the DynamicUser/bind-mount ownership dance vaultwarden needs for
      # its actually-important sqlite db.
      networking.firewall.allowedTCPPorts = [ cfg.port ];
    };

    bindMounts = lib.optionalAttrs hasEndpointsFile {
      ${endpointsPath} = {
        hostPath = "${cfg.endpointsFile}";
        isReadOnly = true;
      };
    };
  });
}
