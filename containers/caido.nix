{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.caido;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  imports = [ ../nixosModules/backup-engine ];

  options.my.containers.caido = {
    enable = lib.mkEnableOption "Caido Web Security Proxy & Auditing Daemon Container";
    ip = lib.mkOption {
      type = lib.types.str;
      description = "Container IP on the cbr0 bridge.";
    };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/images/caido";
      description = "Host directory holding persistent Caido workspace and certificate data.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port on which Caido UI and proxy listener bind.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "2G";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkContainer {
        inherit config;
        name = "caido";
        inherit cfg;
        innerConfig = {
          nixpkgs.config.allowUnfree = true;

          users.users.caido = {
            isSystemUser = true;
            group = "caido";
            home = "/var/lib/caido";
          };
          users.groups.caido = { };

          systemd.services.caido = {
            description = "Caido Web Security Auditing Daemon";
            after = [ "network.target" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              ExecStart = "${pkgs.caido-cli}/bin/caido-cli --listen 0.0.0.0:${toString cfg.port} --data-path /var/lib/caido --no-open";
              Restart = "on-failure";
              User = "caido";
              Group = "caido";
              WorkingDirectory = "/var/lib/caido";
            };
          };

          networking.firewall.allowedTCPPorts = [ cfg.port ];
        };

        bindMounts = {
          "/var/lib/caido" = {
            hostPath = cfg.hostDataDir;
            isReadOnly = false;
          };
        };
      })
      {
        my.backup.items.caido = {
          tier = "secure";
          paths = [ cfg.hostDataDir ];
        };
      }
    ]
  );
}
