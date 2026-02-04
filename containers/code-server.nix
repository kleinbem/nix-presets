{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.my.containers.code-server;
in
{
  options.my.containers.code-server = {
    enable = lib.mkEnableOption "Code-Server Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostBridge = lib.mkOption {
      type = lib.types.str;
      default = "incusbr0";
    };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    hostName = lib.mkOption {
      type = lib.types.str;
      default = "code-server";
    };
  };

  config = lib.mkIf cfg.enable {
    containers.code-server = {
      autoStart = true;
      privateNetwork = true;
      hostBridge = cfg.hostBridge;
      localAddress = cfg.ip;

      config =
        { config, pkgs, ... }:
        {
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

          users.users.martin = {
            isNormalUser = true;
            uid = 1000;
            extraGroups = [ "wheel" ];
            initialPassword = "martin";
          };

          services.code-server = {
            enable = true;
            user = "martin";
            group = "users";
            host = "0.0.0.0";
            port = 4444;
            auth = "none";
            disableTelemetry = true;
          };

          networking.firewall.allowedTCPPorts = [ 4444 ];
          system.stateVersion = "25.11";
        };

      bindMounts = {
        "/home/martin/Develop" = {
          hostPath = cfg.hostDataDir;
          isReadOnly = false;
        };
      };
    };
  };
}
