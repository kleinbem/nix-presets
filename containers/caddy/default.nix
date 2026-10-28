{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.caddy;
  # Import our clean helpers
  h = import ./helpers.nix { inherit lib; };
  # Some vhost wants a publicly trusted certificate via Cloudflare DNS-01
  # (helpers.nix mkTls). Derived from proxyTargets alone, so the closure
  # container-factory builds matches the host's without a factory override.
  acmeDns = lib.any (node: node.publicCert or false) (lib.attrValues cfg.proxyTargets);
  tlsOpts = import ../../lib/tls-options.nix { inherit lib; };
in
{
  imports = [ ../../nixosModules/backup-engine ];

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
      description = "The IP address of the Caddy container.";
    };
    proxyTargets = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = { };
      description = ''
        Map of service name -> node config to reverse-proxy (the caller's
        equivalent of an inventory filtered to entries with an
        externalPort). Passed from host config, which computes it from
        its own inventory -- this preset has no inventory of its own. See
        helpers.nix's genVHosts for the fields read per entry (ip, port,
        externalPort, domain, extraDomains, mtls, secure, auth,
        authExcludePaths, maintenance).
      '';
    };
    globalMaintenance = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "When true, every proxied vhost serves a maintenance page instead of reverse-proxying.";
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Host path to an env file (bind-mounted to /run/secrets/caddy.env)
        with `CLOUDFLARE_API_TOKEN=…`: a token with Zone Read + DNS Write on
        the zone, for the DNS-01 challenge of nodes with `publicCert = true`.
        Unused by `tls internal` vhosts.
      '';
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
        # Bind-mounts to /run/secrets/caddy.env — see nix-gantry's
        # mkContainer secretsFile.
        inherit (cfg) secretsFile;
        secretsFilePath = "/run/secrets/caddy.env";
        innerConfig =
          { pkgs, ... }:
          {
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
              # caddy-dns/cloudflare for publicCert vhosts. The hash covers the
              # vendored Go modules of this Caddy version plus the plugin: a
              # nixpkgs bump that changes caddy fails the build here until the
              # hash is updated (build with lib.fakeHash to get the new one).
              package = lib.mkIf acmeDns (
                pkgs.caddy.withPlugins {
                  plugins = [ "github.com/caddy-dns/cloudflare@v0.2.4" ];
                  hash = "sha256-tubXIDCJnO2mvdnPlZclwDhNGaeeYLSt7lnni3+pXDo=";
                }
              );

              # Restore the full generative logic with proven fixes
              virtualHosts =
                (h.genVHosts {
                  inherit (cfg) proxyTargets hostIP;
                  isGlobalMaint = cfg.globalMaintenance;
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

            systemd.services.caddy.serviceConfig = {
              AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
              # CLOUDFLARE_API_TOKEN for the DNS-01 challenge (secretsFile).
              EnvironmentFile = lib.mkIf acmeDns "/run/secrets/caddy.env";
            };

            networking.firewall.allowedTCPPorts = [
              80
              443
            ]
            ++ (lib.mapAttrsToList (_: node: node.externalPort) cfg.proxyTargets);

            # Ensure the bind-mount points exist inside the container
            systemd.tmpfiles.rules = [
              "d /etc/pki 0755 root root - -"
              "d /etc/pki/internal 0755 root root - -"
            ];
          };

        bindMounts =
          (lib.optionalAttrs (cfg.hostDataDir != null) {
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
      } # Caddy's local CA — every fleet browser/NSS store trusts this root,
      # so losing it means re-trusting fleet-wide. ACME certs themselves are
      # re-issuable and deliberately not included.
      (lib.mkIf (cfg.hostDataDir != null) {
        my.backup.items.caddy-pki = {
          tier = "secure";
          paths = [ "${cfg.hostDataDir}/.local/share/caddy/pki" ];
        };
      })
    ]
  );
}
