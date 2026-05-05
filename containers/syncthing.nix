{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.syncthing;
  inherit (self.lib) mkContainer;
in
{
  options.my.containers.syncthing = {
    enable = lib.mkEnableOption "Syncthing Native Container";
    ip = lib.mkOption {
      type = lib.types.str;
      default = "10.85.46.127/24";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "martin";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "512M";
    };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/syncthing/config";
      description = "Host directory for Syncthing configuration persistence.";
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a file containing secrets for Syncthing (e.g. STGUIADDRESS).";
    };
    vaults = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Map of container paths to host paths for shared folders.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.recursiveUpdate
      (mkContainer {
        inherit config;
        name = "syncthing";
        cfg = cfg // {
          privateUsers = "no";
        };

        innerConfig = _: {
          services.syncthing = {
            enable = true;
            inherit (cfg) user;
            group = "users";
            dataDir = "/home/${cfg.user}"; # Use home as base for dynamic vaults
            configDir = "/home/${cfg.user}/.config/syncthing";
            guiAddress = "0.0.0.0:8384";
            overrideDevices = false;
            overrideFolders = false;
            settings.gui.insecureSkipHostcheck = true;
          };

          # Load secrets if provided
          systemd.services.syncthing.serviceConfig.EnvironmentFile = lib.mkIf (
            cfg.secretsFile != null
          ) "/run/secrets/syncthing.env";

          # Open firewall for Syncthing
          networking.firewall = {
            allowedTCPPorts = [
              8384
              22000
            ];
            allowedUDPPorts = [
              22000
              21027
            ];
          };

          # Ensure the user exists inside the container with the same UID/GID
          users.users.${cfg.user} = {
            isNormalUser = true;
            uid = 1000;
            extraGroups = [ "users" ];
          };
        };

        bindMounts =
          lib.mapAttrs (_name: hostPath: {
            inherit hostPath;
            isReadOnly = false;
          }) cfg.vaults
          // (
            if cfg.secretsFile != null then
              {
                "/run/secrets/syncthing.env" = {
                  hostPath = cfg.secretsFile;
                  isReadOnly = true;
                };
              }
            else
              { }
          )
          // {
            # Persist configuration
            "/home/${cfg.user}/.config/syncthing" = {
              hostPath = cfg.hostDataDir;
              isReadOnly = false;
            };
          };
      })
      {
        # Ensure host bind-mount directories exist before nspawn starts.
        systemd.services."container@syncthing".preStart = ''
          mkdir -p ${cfg.hostDataDir}
          chown ${cfg.user}:users ${cfg.hostDataDir}
        '';
      }
  );
}
