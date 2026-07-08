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
    # Static file-server vhosts that DON'T fit the reverse-proxy pattern
    # (inventory.nix:network.nodes). Each entry produces a Caddy vhost
    # serving the bind-mounted directory directly. Example:
    #   staticSites."team.kleinbem.dev" = {
    #     hostPath = "/home/martin/Develop/.../nix-config/docs";
    #     index    = "TEAM.html";          # default file served at /
    #   };
    staticSites = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            hostPath = lib.mkOption {
              type = lib.types.str;
              description = "Absolute host path bind-mounted into the container at /var/www/<domain>/.";
            };
            index = lib.mkOption {
              type = lib.types.str;
              default = "index.html";
              description = "Default file served when the URL ends in /.";
            };
          };
        }
      );
      default = { };
      description = "Map of domain → static-site config. Produces one Caddy vhost per entry, serving files via file_server (no reverse-proxy).";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (self.lib.mkContainer {
        inherit config;
        name = "caddy";
        cfg = cfg // {
          privateUsers = "no";
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
            logFormat = "output stderr";
            globalConfig = "debug";

            # Restore the full generative logic with proven fixes
            virtualHosts =
              let
                authNode = inv.nodes.authelia or { };
                authDomain = authNode.domain or "";
                authUrl =
                  if authDomain != "" then
                    "https://${authDomain}/"
                  else if myInventory.hosts.${config.networking.hostName} ? netbirdIp then
                    "https://${myInventory.hosts.${config.networking.hostName}.netbirdIp}:${
                      toString (authNode.externalPort or 9091)
                    }/"
                  else
                    "https://authelia.local/";
              in
              (h.genVHosts {
                inherit proxyTargets authUrl;
                inherit (cfg) hostIP;
                isGlobalMaint = myInventory.globalMaintenance or false;
                helpers = h;
              })
              // (
                # Static-site vhosts (file_server). Each entry in
                # cfg.staticSites becomes one vhost.
                lib.mapAttrs' (
                  domain: site:
                  lib.nameValuePair domain {
                    logFormat = "output stderr";
                    extraConfig = ''
                      tls internal
                      root * /var/www/${domain}
                      try_files {path} {path}/${site.index}
                      file_server
                    '';
                  }
                ) cfg.staticSites
              );
          };

          systemd.services.caddy.serviceConfig.AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];

          networking.firewall.allowedTCPPorts = [
            80
            443
          ]
          ++ (lib.mapAttrsToList (_: node: node.externalPort) proxyTargets);

          # Ensure the bind-mount points exist inside the container
          systemd.tmpfiles.rules = [
            "d /etc/pki 0755 root root - -"
            "d /etc/pki/internal 0755 root root - -"
          ];
        };

        bindMounts =
          (lib.mkIf (cfg.hostDataDir != null) {
            "/var/lib/caddy" = {
              hostPath = cfg.hostDataDir;
              isReadOnly = false;
            };
          })
          // {
            # Manually mount the certificates to avoid the factory's sidecar conflict
            "/etc/pki/internal/ca.crt" = {
              hostPath = "/nix/persist/pki/internal/ca.crt";
              isReadOnly = true;
            };
            "/etc/pki/internal/certs" = {
              hostPath = "/nix/persist/pki/internal/certs";
              isReadOnly = true;
            };
          }
          # One bind-mount per static-site entry, read-only.
          // (lib.mapAttrs' (
            domain: site:
            lib.nameValuePair "/var/www/${domain}" {
              inherit (site) hostPath;
              isReadOnly = true;
            }
          ) cfg.staticSites);
      })
      {
        systemd.tmpfiles.rules = lib.mkIf (cfg.hostDataDir != null) [
          "Z ${cfg.hostDataDir} 0755 3000 3000 - -"
        ];
      }
    ]
  );
}
