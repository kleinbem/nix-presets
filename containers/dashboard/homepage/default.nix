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
    self.lib.mkContainer { inherit config;
      name = "dashboard-homepage";
      cfg = cfg;
      innerConfig = {
        # Use the native NixOS module for Homepage
        services.homepage-dashboard = {
          enable = true;
          listenPort = 8082;
          openFirewall = true;
          inherit (homepageConfig) services widgets settings;
          customCSS = builtins.readFile ./custom.css;
          # Allow access from any host (fixes "Host validation failed")
          allowedHosts = "*,10.85.46.103,10.85.46.103:8082,0.0.0.0,0.0.0.0:8082";
        };

        systemd.services.homepage-dashboard.environment = {
          # Disable Host header check (Next.js specific)
          "NEXT_PUBLIC_DISABLE_HOST_CHECK" = "true";
          "HOSTNAME" = "0.0.0.0";
        };

        systemd.services.homepage-dashboard.serviceConfig.EnvironmentFile = "/run/secrets/homepage.env";

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
