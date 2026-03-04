{ self }:
{
  config,
  lib,
  pkgs,
  myInventory,
  ...
}:
let
  cfg = config.my.containers.dashboard;
  inv = myInventory.network;

  # Import helpers
  h = import ./helpers.nix { inherit lib inv; };

  # Filter nodes suitable for the dashboard
  dashboardNodes = lib.filterAttrs (_: node: node ? meta) inv.nodes;

  # Generate dashboard data as JSON
  dashboardData = h.genData {
    inherit dashboardNodes;
    inherit (cfg) hostBridgeIp;
  };

in
{
  imports = [ (import ./options.nix { inherit lib; }) ];

  config = lib.mkIf cfg.enable (
    self.lib.mkContainer { inherit config;
      name = "dashboard";
      cfg = cfg;
      innerConfig = {
        services.nginx = {
          enable = true;
          virtualHosts."dashboard.local" = {
            default = true;
            # Serve the static UI assets and the generated data.json
            root =
              pkgs.runCommand "dashboard-webapp"
                {
                  # Pass files as strings or symlinks
                  ui = ./ui;
                  dataJson = builtins.toJSON dashboardData;
                }
                ''
                  mkdir -p $out
                  cp -r $ui/* $out/
                  echo "$dataJson" > $out/data.json
                '';
          };
        };
        networking.firewall.allowedTCPPorts = [ 80 ];
      };
    }
  );
}
