{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.my.containers.silverbullet;
in
{
  options.my.containers.silverbullet = {
    enable = lib.mkEnableOption "SilverBullet Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostBridge = lib.mkOption {
      type = lib.types.str;
      default = "incusbr0";
    };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    hostName = lib.mkOption {
      type = lib.types.str;
      default = "silverbullet";
    };
  };

  config = lib.mkIf cfg.enable {
    containers.silverbullet = {
      autoStart = true;
      privateNetwork = true;
      hostBridge = cfg.hostBridge;
      localAddress = cfg.ip;

      config =
        { config, pkgs, ... }:
        {
          networking.firewall.enable = false;
          networking.hostName = cfg.hostName;
          services.avahi = {
            enable = true;
            nssmdns4 = true;
            publish = {
              enable = true;
              addresses = true;
              workstation = true;
            };
            openFirewall = true;
          };

          systemd.services.silverbullet = {
            description = "SilverBullet Notes Server";
            after = [ "network.target" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              DynamicUser = true;
              StateDirectory = "silverbullet";
              WorkingDirectory = "/var/lib/silverbullet";
              ExecStart = "${pkgs.silverbullet}/bin/silverbullet --hostname 0.0.0.0 --port 3333 /var/lib/silverbullet";
              Restart = "always";
            };
          };
          networking.firewall.allowedTCPPorts = [ 3333 ];
          system.stateVersion = "25.11";
        };

      bindMounts = {
        "/var/lib/silverbullet" = {
          hostPath = cfg.hostDataDir;
          isReadOnly = false;
        };
      };
    };
  };
}
