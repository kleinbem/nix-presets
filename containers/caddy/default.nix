{ self }:
{
  config,
  lib,
  myInventory,
  ...
}:
let
  cfg = config.my.containers.caddy;
  # Import our clean helpers
  h = import ./helpers.nix { inherit lib; };
  tlsOpts = import ../../lib/tls-options.nix { inherit lib; };

  inv = myInventory.network;
  proxyTargets = lib.filterAttrs (_: v: v ? externalPort) inv.nodes;
in
{
  options.my.containers.caddy = {
    enable = lib.mkEnableOption "Caddy Reverse Proxy Container";
    ip = lib.mkOption { type = lib.types.str; }; # Passed from host config (which gets it from inventory)
    hostDataDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host path to mount into /var/lib/caddy for persistent data.";
    };
    hostBridge = lib.mkOption {
      type = lib.types.str;
      default = config.my.network.bridge;
      description = "The name of the host bridge interface to connect the container to.";
    };
    hostIP = lib.mkOption {
      type = lib.types.str;
      default = inv.nodes.caddy.ip;
      description = "The IP address of the Caddy container.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "512M";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (self.lib.mkContainer {
        inherit config;
        name = "caddy";
        cfg = cfg // {
          hostDataDir = null;
        };
        innerConfig = {
          users.groups.caddy.gid = lib.mkForce 3000;
          users.users.caddy = {
            uid = lib.mkForce 3000;
            isSystemUser = true;
            group = "caddy";
          };

          services.caddy = {
            enable = true;
            globalConfig = "debug";

            # This is now just one clean line of logic
            virtualHosts = h.genVHosts {
              inherit proxyTargets;
              inherit (cfg) hostIP;
              isGlobalMaint = inv.globalMaintenance or false;
              helpers = h;
            };
          };

          systemd.services.caddy.serviceConfig.AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];

          networking.firewall.allowedTCPPorts = [
            80
            443
          ]
          ++ (lib.mapAttrsToList (_: node: node.externalPort) proxyTargets);
        };

        bindMounts = lib.mkIf (cfg.hostDataDir != null) {
          "/var/lib/caddy" = {
            hostPath = cfg.hostDataDir;
            isReadOnly = false;
          };
        };
      })
      {
        systemd.tmpfiles.rules = lib.mkIf (cfg.hostDataDir != null) [
          "Z ${cfg.hostDataDir} 0755 3000 3000 - -"
        ];
      }
    ]
  );
}
