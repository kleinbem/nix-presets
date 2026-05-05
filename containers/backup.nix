{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.backup;
  inherit (self.lib) mkContainer;
in
{
  options.my.containers.backup = {
    enable = lib.mkEnableOption "Restic Daily Backup Container";
    ip = lib.mkOption {
      type = lib.types.str;
      default = "10.85.46.130/24";
    };
    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to the Restic password file (from sops).";
    };
    rcloneConfigFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to the rclone config file (from sops).";
    };
    targets = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Map of container paths to host paths for read-only backup.";
    };
    systemTargets = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Map of container paths to host paths for read-only system backup.";
    };
    systemPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to the system Restic password file (from sops).";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "2G";
    };
  };

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "backup";
    cfg = cfg // {
      privateUsers = "no";
    }; # Needed to reliably read host files

    innerConfig =
      { pkgs, ... }:
      {
        services.restic.backups.daily = {
          initialize = true;
          user = "root"; # Run as root inside the container
          repository = "rclone:gdrive:backups/nixos";
          passwordFile = if cfg.passwordFile != null then "/run/secrets/restic_password" else null;
          rcloneConfigFile = if cfg.rcloneConfigFile != null then "/run/secrets/rclone_config" else null;

          extraOptions = [
            "rclone.args=\"--tpslimit 5 --fast-list --drive-chunk-size 64M\""
          ];

          # Iterate over the container paths we defined
          paths = lib.mapAttrsToList (containerPath: _hostPath: containerPath) cfg.targets;

          exclude = [
            # Cache & Temporary
            "**/.cache"
            "**/.local/share/Trash"
            "**/Downloads"

            # Cloud Drives
            "**/GoogleDrive"
            "**/OneDrive"
            "**/Cloud"

            # Development
            "**/node_modules"
            "**/target"
            "**/result"
            "**/__pycache__"
            "**/.venv"

            # Large files handled elsewhere
            "**/*.qcow2"
            "**/*.iso"
          ];

          pruneOpts = [
            "--keep-daily 7"
            "--keep-weekly 4"
            "--keep-monthly 6"
          ];

          timerConfig = {
            OnCalendar = "daily";
            Persistent = true;
          };
        };

        services.restic.backups.system = {
          initialize = false;
          user = "root";
          repository = "rclone:gdrive:backups/nixos-system";
          passwordFile =
            if cfg.systemPasswordFile != null then "/run/secrets/restic_system_password" else null;
          rcloneConfigFile = if cfg.rcloneConfigFile != null then "/run/secrets/rclone_config" else null;

          extraOptions = [
            "rclone.args=\"--tpslimit 3 --fast-list --drive-chunk-size 128M\""
          ];

          paths = lib.mapAttrsToList (containerPath: _hostPath: containerPath) cfg.systemTargets;

          exclude = [
            "**/tmp"
            "**/.cache"
          ];

          pruneOpts = [
            "--keep-daily 14"
            "--keep-weekly 8"
            "--keep-monthly 12"
          ];

          timerConfig = {
            OnCalendar = "daily";
            Persistent = true;
            RandomizedDelaySec = "2h";
          };
        };

        environment.systemPackages = [ pkgs.rclone ];
      };

    # Read-Only Bind Mounts
    bindMounts =
      lib.mapAttrs (_containerPath: hostPath: {
        inherit hostPath;
        isReadOnly = true; # CRITICAL: The backup container cannot modify these files
      }) (cfg.targets // cfg.systemTargets)
      // (
        if cfg.passwordFile != null then
          {
            "/run/secrets/restic_password" = {
              hostPath = cfg.passwordFile;
              isReadOnly = true;
            };
          }
        else
          { }
      )
      // (
        if cfg.systemPasswordFile != null then
          {
            "/run/secrets/restic_system_password" = {
              hostPath = cfg.systemPasswordFile;
              isReadOnly = true;
            };
          }
        else
          { }
      )
      // (
        if cfg.rcloneConfigFile != null then
          {
            "/run/secrets/rclone_config" = {
              hostPath = cfg.rcloneConfigFile;
              isReadOnly = true;
            };
          }
        else
          { }
      );
  });
}
