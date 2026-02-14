{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.my.containers.n8n;
in
{
  options.my.containers.n8n = {
    enable = lib.mkEnableOption "n8n Container";

    ip = lib.mkOption {
      type = lib.types.str;
      description = "Static IP Address (CIDR notation preferred, e.g. 10.85.46.99/24)";
    };

    hostBridge = lib.mkOption {
      type = lib.types.str;
      default = "incusbr0";
      description = "Bridge interface on the host";
    };

    hostDataDir = lib.mkOption {
      type = lib.types.str;
      description = "Absolute path on host for persistence";
    };

    hostName = lib.mkOption {
      type = lib.types.str;
      default = "n8n";
      description = "Hostname for the container (will be reachable via .local)";
    };
  };

  config = lib.mkIf cfg.enable {
    containers.n8n = {
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

          services.n8n = {
            enable = true;
            openFirewall = true;
            environment = {
              N8N_LISTEN_ADDRESS = "0.0.0.0";
              N8N_PORT = "5678";
              N8N_PROTOCOL = "http";
              N8N_SECURE_COOKIE = "false";
            };
          };

          systemd.services.n8n.serviceConfig = {
            DynamicUser = pkgs.lib.mkForce false;
            # Zero Trust Hardening
            ProtectSystem = "strict";
            ProtectHome = true;
            # PrivateTmp = true; # Conflict with upstream n8n module
            # PrivateDevices = true; # Conflict with upstream n8n module
            # ProtectKernelTunables = true; # Conflict with upstream n8n module
            # ProtectControlGroups = true; # Conflict with upstream n8n module
            # RestrictSUIDSGID = true; # Conflict with upstream n8n module
            # RemoveIPC = true; # Conflict with upstream n8n module
            # NoNewPrivileges = true; # Conflict with upstream n8n module
            # RestrictRealtime = true; # Conflict with upstream n8n module
            # MemoryDenyWriteExecute = true; # Conflict with upstream n8n module
            # Allow writing to state dir (bind mounted)
            ReadWritePaths = [ "/var/lib/n8n" ];
          };
          system.stateVersion = "25.11";
        };

      bindMounts = {
        "/var/lib/n8n" = {
          hostPath = cfg.hostDataDir;
          isReadOnly = false;
        };
      };
    };
  };
}
