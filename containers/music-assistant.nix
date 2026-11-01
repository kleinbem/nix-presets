{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.music-assistant;
  inherit (self.lib) mkContainer;
in
{
  imports = [ ../nixosModules/backup-engine ];

  options.my.containers.music-assistant = {
    enable = lib.mkEnableOption "Music Assistant container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/music-assistant";
    };
    mediaDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/music";
      description = ''
        Host folder with the user's own music files, mounted read-only at
        /media/music for Music Assistant's local filesystem provider. Files
        need to be world-readable: the service runs as a DynamicUser.
      '';
    };
    providers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "chromecast"
        "filesystem_local"
        "hass"
        "hass_players"
        "radiobrowser"
        "sendspin"
        "tunein"
        "ytmusic"
      ];
      description = "Music Assistant providers whose dependencies go into the closure.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "1G";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkContainer {
        inherit config;
        name = "music-assistant";
        inherit cfg;
        innerConfig = {
          services.music-assistant = {
            enable = true;
            inherit (cfg) providers;
            # Stream port 8097 and Sendspin 8927 for the players.
            openFirewall = true;
          };
          # Web UI and the API Home Assistant's integration talks to.
          networking.firewall.allowedTCPPorts = [ 8095 ];
        };
        bindMounts = {
          # services.music-assistant runs as a DynamicUser, so its state is
          # the private path.
          "/var/lib/private/music-assistant" = {
            hostPath = cfg.hostDataDir;
            isReadOnly = false;
          };
        }
        // lib.optionalAttrs (cfg.mediaDir != null) {
          "/media/music" = {
            hostPath = cfg.mediaDir;
            isReadOnly = true;
          };
        };
      })
      {
        # The databases are written while the service runs; copy them with
        # sqlite's `.backup` instead of the live files. The cache is left out.
        my.backup.items.music-assistant = {
          tier = "bulk";
          sqlite = [
            "${cfg.hostDataDir}/library.db"
            "${cfg.hostDataDir}/auth.db"
          ];
          paths = [ cfg.hostDataDir ];
          exclude = [
            "${cfg.hostDataDir}/library.db*"
            "${cfg.hostDataDir}/auth.db*"
            "${cfg.hostDataDir}/.cache"
          ];
        };
      }
    ]
  );
}
