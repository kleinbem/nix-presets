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

  caCertPath = "/run/caddy-ca/root.crt";

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
          # Homepage matches the Host header literally: "*" does not allow
          # any host, so the real domain has to be listed.
          allowedHosts = "${inv.nodes.dashboard.domain},${inv.nodes.dashboard.ip},${inv.nodes.dashboard.ip}:8082,0.0.0.0,0.0.0.0:8082";
        };

        systemd.services.homepage-dashboard.environment = {
          # Disable Host header check (Next.js specific)
          "NEXT_PUBLIC_DISABLE_HOST_CHECK" = "true";
          "HOSTNAME" = "0.0.0.0";
          # Trust the Caddy CA for health pings. Set unconditionally so the
          # cached closure fits every host; Node only warns if it's missing.
          "NODE_EXTRA_CA_CERTS" = caCertPath;
        };

        # `-` prefix: optional. Without a secretsFile, widgets that need an
        # API key (n8n, Grafana) just render unconfigured instead of the
        # whole unit hard-failing to start on a missing EnvironmentFile.
        systemd.services.homepage-dashboard.serviceConfig.EnvironmentFile = "-/run/secrets/homepage.env";

        # Allow port 8082
        networking.firewall.allowedTCPPorts = [ 8082 ];
      };
      bindMounts =
        lib.optionalAttrs (cfg.secretsFile != null) {
          "/run/secrets/homepage.env" = {
            hostPath = cfg.secretsFile;
            isReadOnly = true;
          };
        }
        // lib.optionalAttrs (cfg.caCertFile != null) {
          ${caCertPath} = {
            hostPath = cfg.caCertFile;
            isReadOnly = true;
          };
        };
    }
  );
}
