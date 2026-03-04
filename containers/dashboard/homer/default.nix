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

  # Import Homer specific helpers
  h = import ./helpers.nix { inherit lib inv; };

  # Filter nodes for the dashboard
  dashboardNodes = lib.filterAttrs (_: node: node ? meta) inv.nodes;

  # Generate Homer config.yml structure
  homerConfig = h.genHomerConfig { inherit dashboardNodes; };

  # Create a derivation for the Homer runtime configuration
  homerDist =
    pkgs.runCommand "homer-dist"
      {
        nativeBuildInputs = [ pkgs.remarshal ];
        homer = pkgs.homer;
        configYml = builtins.toJSON homerConfig;
      }
      ''
        mkdir -p $out/assets
        cp -r $homer/* $out/
        # Homer looks for assets/config.yml and prefers real YAML
        echo "$configYml" | json2yaml > $out/assets/config.yml
      '';

in
{
  imports = [ (import ../options.nix { inherit lib; }) ];

  # Note: Uses the same options as the standard dashboard
  config = lib.mkIf cfg.enable (
    self.lib.mkContainer { inherit config;
      name = "dashboard-homer";
      cfg = cfg;
      innerConfig = {
        services.nginx = {
          enable = true;
          virtualHosts."dashboard.local" = {
            default = true;
            root = homerDist;
          };
        };
        networking.firewall.allowedTCPPorts = [ 80 ];
      };
    }
  );
}
