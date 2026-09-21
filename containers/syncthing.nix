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

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "syncthing";
    cfg = cfg // {
      privateUsers = "no";
    };
    # Bind-mounts to /run/secrets/syncthing.env, matching this preset's
    # own naming — see factory.nix's secretsFile doc comment.
    inherit (cfg) secretsFile;

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
      // {
        # Persist configuration. hostDataDir itself (owner 1000:100,
        # matching this container's hardcoded uid=1000 user) is created
        # automatically by mkContainer's own tmpfiles rule — the old
        # preStart mkdir+chown wrapper here was fully redundant.
        "/home/${cfg.user}/.config/syncthing" = {
          hostPath = cfg.hostDataDir;
          isReadOnly = false;
        };
      };
  });
}
