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
          # NOT gated on cfg here — innerConfig is evaluated by
          # container-factory (ADR-002: one shared closure, built once),
          # so cfg is container-factory's OWN (nonexistent) config, never
          # the consuming host's. Confirmed live on nasbook 2026-09-18,
          # same bug class as paperless's passwordFile: both restic
          # backup jobs failed every single run with "Fatal: Resolving
          # password failed: /run/secrets/dummy does not exist" — the
          # real secret WAS correctly bind-mounted to
          # /run/secrets/restic_password by the (per-host, correctly
          # evaluated) bindMounts below, this option just never pointed
          # at it. Point at the fixed in-container paths unconditionally;
          # a host with nothing configured just gets a missing-file error
          # instead, which is the correct behavior for backup without
          # credentials anyway.
          passwordFile = "/run/secrets/restic_password";
          rcloneConfigFile = "/run/secrets/rclone_config";

          extraOptions = [
            # restic's rclone backend default is "serve restic --stdio";
            # rclone.args REPLACES that default rather than appending to
            # it, so the old value (tuning flags only) made restic invoke
            # rclone as `rclone <tuning-flags> gdrive:backups/nixos-system`,
            # with no "serve restic --stdio" verb at all — rclone then
            # tried to parse the remote path itself as a subcommand and
            # failed with "unknown command ... for rclone".
            #
            # The embedded double quotes here are NOT redundant — NixOS's
            # restic module writes ExecStart as a plain systemd unit-file
            # command line, which systemd itself word-splits on
            # whitespace. Without quotes around the value, "serve restic
            # --stdio ..." gets split into separate bare argv tokens for
            # restic itself, and restic's cobra CLI treats the first one
            # ("restic") as an attempted subcommand: 'unknown command
            # "restic" for "restic"'. Confirmed both failure modes live on
            # nasbook 2026-09-18, in that order, while fixing this.
            "rclone.args=\"serve restic --stdio --tpslimit 5 --fast-list --drive-chunk-size 64M\""
          ];

          # NOT derived from cfg.targets here — same innerConfig/
          # container-factory scoping issue as passwordFile above, but
          # unfixable with a single fixed secret path since the actual
          # set of host paths genuinely varies per host. Confirmed live
          # on nasbook 2026-09-18: with this reading container-factory's
          # own empty cfg.targets, `paths` evaluated to [] in the built
          # closure, so the NixOS restic module emitted no backup
          # ExecStart at all (only unlock + forget/prune) — the jobs
          # "succeeded" every run without ever backing up anything.
          # Fixed instead by mounting every host target under one fixed,
          # host-independent parent directory (bindMounts below) and
          # just backing up that whole parent — same trick as
          # passwordFile, generalized to a directory instead of a file.
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
          # Same fixed-path fix as services.restic.backups.daily above.
          passwordFile = "/run/secrets/restic_system_password";
          rcloneConfigFile = "/run/secrets/rclone_config";

          extraOptions = [
            # Same rclone.args fix as services.restic.backups.daily above
            # (quotes required — see the comment there).
            "rclone.args=\"serve restic --stdio --tpslimit 3 --fast-list --drive-chunk-size 128M\""
          ];

          # Same fixed-parent-directory fix as services.restic.backups.daily
          # above.
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

    # Read-Only Bind Mounts
    #
    # Mounted under fixed, host-independent parent directories
    # (/mnt/backup-targets, /mnt/backup-system-targets) rather than at the
    # arbitrary container-path keys of cfg.targets/cfg.systemTargets — the
    # `paths` options above back up those two fixed parents wholesale, so
    # each host's real target directories just need to appear as SOME
    # subdirectory underneath, keyed by a sanitized version of whatever
    # container path the host chose (only used here as a unique label now,
    # not as the actual in-container path).
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
