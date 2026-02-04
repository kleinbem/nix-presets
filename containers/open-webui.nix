{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.my.containers.open-webui;
in
{
  options.my.containers.open-webui = {
    enable = lib.mkEnableOption "Open WebUI Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostBridge = lib.mkOption {
      type = lib.types.str;
      default = "incusbr0";
    };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    ollamaUrl = lib.mkOption {
      type = lib.types.str;
      example = "http://10.85.46.1:11434";
    };
    hostName = lib.mkOption {
      type = lib.types.str;
      default = "open-webui";
    };
  };

  config = lib.mkIf cfg.enable {
    containers.open-webui = {
      autoStart = true;
      privateNetwork = true;
      hostBridge = cfg.hostBridge;
      localAddress = cfg.ip;

      config =
        { config, pkgs, ... }:
        {
          nixpkgs.config.allowUnfree = true;
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

          services.open-webui = {
            enable = true;
            host = "0.0.0.0";
            port = 8080;
            environment = {
              OLLAMA_BASE_URL = cfg.ollamaUrl;
            };
          };
          
          # Fix for bind-mount permission issues (Systemd tries to chown bind mount with DynamicUser)
          systemd.services.open-webui.serviceConfig.DynamicUser = lib.mkForce false;
          networking.firewall.allowedTCPPorts = [ 8080 ];
          system.stateVersion = "25.11";
        };

      bindMounts = {
        "/var/lib/open-webui" = {
          hostPath = cfg.hostDataDir;
          isReadOnly = false;
        };
      };
    };
  };
}
