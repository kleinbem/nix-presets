{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.qbittorrent;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  imports = [ ../nixosModules/backup-engine ];

  options.my.containers.qbittorrent = {
    enable = lib.mkEnableOption "qBittorrent-nox Headless Container";
    ip = lib.mkOption {
      type = lib.types.str;
      description = "Container IP on the cbr0 bridge.";
    };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/images/qbittorrent";
      description = "Host directory holding qBittorrent config and torrent state.";
    };
    downloadsDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Downloads";
      description = "Host directory bind-mounted to /data/downloads for torrent data.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "4G";
    };
    webuiPort = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "WebUI port.";
    };
    torrentingPort = lib.mkOption {
      type = lib.types.port;
      default = 6881;
      description = "Port used for incoming BitTorrent peer traffic.";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkContainer {
        inherit config;
        name = "qbittorrent";
        inherit cfg;
        subDirs = [ "config" ];
        innerConfig = {
          services.qbittorrent = {
            enable = true;
            package = pkgs.qbittorrent-nox;
            inherit (cfg) webuiPort;
            inherit (cfg) torrentingPort;
            openFirewall = true;
          };

          # The bind-mount source is created root-owned on the host (below);
          # hand it to the service user from inside, where the name resolves.
          systemd.tmpfiles.rules = [ "d /data/downloads 0755 qbittorrent qbittorrent - -" ];
          systemd.services.qbittorrent.serviceConfig = {
            ReadWritePaths = [
              "/var/lib/qBittorrent"
              "/data/downloads"
            ];
          };

          networking.firewall.allowedTCPPorts = [
            cfg.webuiPort
            cfg.torrentingPort
          ];
          networking.firewall.allowedUDPPorts = [ cfg.torrentingPort ];
        };

        bindMounts = {
          "/var/lib/qBittorrent" = {
            hostPath = "${cfg.hostDataDir}/config";
            isReadOnly = false;
          };
          "/data/downloads" = {
            hostPath = cfg.downloadsDir;
            isReadOnly = false;
          };
        };
      })
      {
        # downloadsDir is a standalone host path, not under hostDataDir, so
        # subDirs doesn't create it. Without it the container fails with
        # "Failed to clone /mnt/data/Downloads" (nasbook, since its data disk
        # was recreated). Ownership is left to the container's own rule.
        systemd.tmpfiles.rules = [ "d ${cfg.downloadsDir} 0755 - - - -" ];
      }
      {
        my.backup.items.qbittorrent = {
          tier = "secure";
          paths = [ "${cfg.hostDataDir}/config" ];
        };
      }
    ]
  );
}
