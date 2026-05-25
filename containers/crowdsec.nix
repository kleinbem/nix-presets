{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.crowdsec;
  inherit (self.lib) mkContainer;
in
{
  options.my.containers.crowdsec = {
    enable = lib.mkEnableOption "CrowdSec LAPI Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "1G";
    };
  };

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "crowdsec";
    cfg = cfg // {
      privateUsers = "no";
    };
    innerConfig = {
      services.crowdsec = {
        enable = true;
        localConfig = {
          acquisitions = [
            {
              source = "journalctl";
              journalctl_args = [
                "-D"
                "/var/log/journal_host"
              ];
              journalctl_filter = [ "_SYSTEMD_UNIT=container@caddy.service" ];
              labels = {
                type = "caddy";
              };
            }
            {
              source = "journalctl";
              journalctl_args = [
                "-D"
                "/var/log/journal_host"
              ];
              journalctl_filter = [ "_SYSTEMD_UNIT=sshd.service" ];
              labels = {
                type = "syslog";
              };
            }
          ];
        };
        settings = {
          general = {
            api = {
              server = {
                listen_uri = "0.0.0.0:8080";
              };
            };
          };
        };
      };

      systemd.services.crowdsec.serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = lib.mkForce "root";
        Group = lib.mkForce "root";
        PrivateUsers = lib.mkForce false;
        ProtectSystem = lib.mkForce "no";
        ProtectHome = lib.mkForce false;
        PrivateTmp = lib.mkForce false;
        PrivateDevices = lib.mkForce false;
        ProtectHostname = lib.mkForce false;
        ProtectClock = lib.mkForce false;
        ProtectKernelTunables = lib.mkForce false;
        ProtectKernelModules = lib.mkForce false;
        ProtectControlGroups = lib.mkForce false;
        ProtectProc = lib.mkForce "default";
        RestrictAddressFamilies = lib.mkForce [ ];
        RestrictNamespaces = lib.mkForce false;
        RestrictRealtime = lib.mkForce false;
        RestrictSUIDSGID = lib.mkForce false;
        SystemCallFilter = lib.mkForce [ ];
        NoNewPrivileges = lib.mkForce false;
        ExecStartPre = [
          "${pkgs.bash}/bin/bash -c '${pkgs.crowdsec}/bin/cscli collections install crowdsecurity/caddy crowdsecurity/sshd crowdsecurity/linux || true'"
          "${pkgs.bash}/bin/bash -c '${pkgs.crowdsec}/bin/cscli bouncers add firewall -k $(cat /var/lib/crowdsec/bouncer-key) 2>/dev/null || true'"
        ];
      };

      networking.firewall.allowedTCPPorts = [ 8080 ];
    };

    bindMounts = {
      "/var/lib/crowdsec" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
      "/var/log/journal_host" = {
        hostPath = "/var/log/journal";
        isReadOnly = true;
      };
    };
  });
}
