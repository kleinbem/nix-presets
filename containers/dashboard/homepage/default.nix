{ self }:
{
  config,
  lib,
  myInventory,
  ...
}:
let
  cfg = config.my.containers.dashboard;
  inv = myInventory.network;

  # Import Homepage specific helpers
  h = import ./helpers.nix { inherit lib inv; };

  # Filter nodes for the dashboard
  dashboardNodes = lib.filterAttrs (_: node: node ? meta) inv.nodes;

  # Generate Homepage config
  homepageConfig = h.genHomepageConfig {
    inherit dashboardNodes;
  };

in
{
  imports = [ (import ../options.nix { inherit lib; }) ];

  config = lib.mkIf cfg.enable (
    self.lib.mkContainer {
      inherit config;
      name = "dashboard-homepage";
      inherit cfg;
      innerConfig = {
        # Use the native NixOS module for Homepage
        services.homepage-dashboard = {
          enable = true;
          listenPort = 8082;
          openFirewall = true;
          inherit (homepageConfig) services widgets settings;
          customCSS = builtins.readFile ./custom.css;
          # A bare "*" entry does NOT mean "allow any host" here — confirmed
          # live 2026-09-21: it still rejected the real public domain
          # ("Host validation failed for: home.kleinbem.dev") despite being
          # first in this list. Homepage matches the Host header against
          # this list literally, so the actual domain has to be listed.
          allowedHosts = "${inv.nodes.dashboard.domain},${inv.nodes.dashboard.ip},${inv.nodes.dashboard.ip}:8082,0.0.0.0,0.0.0.0:8082";
        };

        systemd.services.homepage-dashboard.environment = {
          # Disable Host header check (Next.js specific)
          "NEXT_PUBLIC_DISABLE_HOST_CHECK" = "true";
          "HOSTNAME" = "0.0.0.0";
          # Disable TLS verification so health pings succeed against internal Caddy CA
          "NODE_TLS_REJECT_UNAUTHORIZED" = "0";
        };

        # `-` prefix: optional. Without a secretsFile, widgets that need an
        # API key (n8n, Grafana) just render unconfigured instead of the
        # whole unit hard-failing to start on a missing EnvironmentFile.
        systemd.services.homepage-dashboard.serviceConfig.EnvironmentFile = "-/run/secrets/homepage.env";

        # Allow port 8082
        networking.firewall.allowedTCPPorts = [ 8082 ];
      };
      bindMounts = lib.optionalAttrs (cfg.secretsFile != null) {
        "/run/secrets/homepage.env" = {
          hostPath = cfg.secretsFile;
          isReadOnly = true;
        };
      };
    }
  );
}
