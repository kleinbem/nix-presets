{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.ntfy;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.ntfy = {
    enable = lib.mkEnableOption "ntfy pub/sub notification server container";
    ip = lib.mkOption { type = lib.types.str; };
    baseUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://ntfy.kleinbem.dev";
      description = "Public base URL clients use (behind caddy + Cloudflare tunnel).";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "256M";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "ntfy";
    inherit cfg;
    innerConfig = {
      services.ntfy-sh = {
        enable = true;
        settings = {
          base-url = cfg.baseUrl;
          listen-http = ":2586";
          behind-proxy = true;
          # Message cache is advisory only: the fleet-deploy signal has the
          # nightly autoUpgrade timer as its catch-up path, so losing cached
          # messages on container rebuild is harmless. Keep 12h for the web
          # UI and late long-poll reconnects.
          cache-duration = "12h";
          # Long-poll subscribers sit behind caddy + cloudflared; keepalives
          # below their idle timeouts stop silent connection drops.
          keepalive-interval = "45s";
        };
      };
      networking.firewall.allowedTCPPorts = [ 2586 ];
    };
  });
}
