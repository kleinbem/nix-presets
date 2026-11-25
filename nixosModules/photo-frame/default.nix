{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.my.services.photo-frame;
  python = pkgs.python3.withPackages (p: [
    p.pillow
    p.pillow-heif
  ]);
in
{
  imports = [ ../backup-engine ];

  # Random photos from a folder, sized for wall panels (ESPHome online_image).
  options.my.services.photo-frame = {
    enable = lib.mkEnableOption "photo-frame server for wall panels";
    photoDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/photos";
      description = ''
        Folder with the photos (searched recursively). Must be a real directory, not a
        symlink: the backup item backs up this path. Needs a persistence entry on tmpfs hosts.
      '';
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8099;
    };
    openFirewallOn = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "end0" ];
      description = "Interfaces the port is opened on.";
    };
    supplementaryGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra groups for the service, for a photoDir that is group- but not world-readable.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # ProtectHome hides these from the service.
        assertion =
          !lib.any (p: lib.hasPrefix p cfg.photoDir) [
            "/home"
            "/root"
            "/run/user"
          ];
        message = "my.services.photo-frame.photoDir must not be under /home, /root or /run/user.";
      }
    ];

    systemd.services.photo-frame = {
      description = "Photo-frame server for wall panels";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      environment = {
        PHOTO_DIR = cfg.photoDir;
        LISTEN_PORT = toString cfg.port;
      };
      serviceConfig = {
        ExecStart = "${python.interpreter} ${./photo_frame.py}";
        DynamicUser = true;
        SupplementaryGroups = cfg.supplementaryGroups;
        ReadOnlyPaths = [ cfg.photoDir ];
        Restart = "on-failure";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        MemoryMax = "512M";
      };
    };

    networking.firewall.interfaces = lib.genAttrs cfg.openFirewallOn (_: {
      allowedTCPPorts = [ cfg.port ];
    });

    my.backup.items.photo-frame = {
      tier = "bulk";
      paths = [ cfg.photoDir ];
    };
  };
}
