{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.gatus;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
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
    endpoints = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
      description = ''
        Gatus endpoint definitions (see https://gatus.io/docs#endpoints).
        The actual fleet-specific list belongs on the deploying host, not
        here, so this preset stays portable.
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
        settings = {
          web.port = cfg.port;
          ui.title = "kleinbem Status";
          inherit (cfg) endpoints;
        };
      };
      # In-memory storage only — no bind-mounted data dir. Same call
      # ntfy.nix makes for its message cache: a container rebuild resets
      # uptime history, which is fine for a personal status page and avoids
      # the DynamicUser/bind-mount ownership dance vaultwarden needs for
      # its actually-important sqlite db.
      networking.firewall.allowedTCPPorts = [ cfg.port ];
    };
  });
}
