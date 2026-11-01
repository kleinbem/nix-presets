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
      type = lib.types.unspecified;
      default = null;
      description = "Path to the Restic password file (from sops).";
    };
    rcloneConfigFile = lib.mkOption {
      type = lib.types.unspecified;
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
      type = lib.types.unspecified;
      default = null;
      description = "Path to the system Restic password file (from sops).";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.unspecified;
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
          # Fixed in-container paths, not cfg: container-factory builds innerConfig
          # once for all hosts (ADR-002), so cfg here is never the host's. The per-host
          # bindMounts below put the real secrets at these paths.
          passwordFile = "/run/secrets/restic_password";
          rcloneConfigFile = "/run/secrets/rclone_config";

          extraOptions = [
            # rclone.args replaces restic's default "serve restic --stdio", so the verb
            # must be repeated here. The inner quotes are needed: systemd word-splits
            # ExecStart, and restic would read "restic" as a subcommand.
            "rclone.args=\"serve restic --stdio --tpslimit 5 --fast-list --drive-chunk-size 64M\""
          ];

          # Not cfg.targets: same container-factory scoping, so it would be [] and
          # restic would back up nothing. bindMounts below put every host target under
          # this one fixed parent instead.
          paths = [ "/mnt/backup-targets" ];

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
          # Same fixed paths as the daily job.
          passwordFile = "/run/secrets/restic_system_password";
          rcloneConfigFile = "/run/secrets/rclone_config";

          extraOptions = [
            # Same rclone.args as the daily job (quotes required).
            "rclone.args=\"serve restic --stdio --tpslimit 3 --fast-list --drive-chunk-size 128M\""
          ];

          # Same fixed-parent-directory trick as the daily job.
          paths = [ "/mnt/backup-system-targets" ];

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

        environment.systemPackages = [
          pkgs.rclone
          pkgs.restic
        ];
      };

    # Read-only bind mounts. Targets go under the fixed parents
    # /mnt/backup-targets and /mnt/backup-system-targets, which the `paths` above
    # back up whole; the sanitized container path is only a unique subdir name.
    bindMounts =
      let
        sanitize = path: lib.replaceStrings [ "/" ] [ "-" ] (lib.removePrefix "/" path);
      in
      (lib.mapAttrs' (
        containerPath: hostPath:
        lib.nameValuePair "/mnt/backup-targets/${sanitize containerPath}" {
          inherit hostPath;
          isReadOnly = true; # CRITICAL: The backup container cannot modify these files
        }
      ) cfg.targets)
      // (lib.mapAttrs' (
        containerPath: hostPath:
        lib.nameValuePair "/mnt/backup-system-targets/${sanitize containerPath}" {
          inherit hostPath;
          isReadOnly = true;
        }
      ) cfg.systemTargets)
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
