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

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkContainer {
        inherit config;
        name = "crowdsec";
        cfg = cfg // {
          privateUsers = "no";
          # The host directory is created as root, but the container's tmpfiles
          # will recursively chown it to crowdsec:crowdsec.
          dataDirOwner = "root";
          dataDirGroup = "root";
        };
        innerConfig = {
          systemd.tmpfiles.rules = [ "Z /var/lib/crowdsec - crowdsec crowdsec - -" ];
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
              lapi.credentialsFile = "/var/lib/crowdsec/local_api_credentials.yaml";
              general = {
                api = {
                  server = {
                    enable = true;
                    listen_uri = "0.0.0.0:8080";
                  };
                };
              };
            };
          };

          systemd.services.crowdsec = {
            serviceConfig = {
              ExecStartPre = [
                "${pkgs.bash}/bin/bash -c '${pkgs.crowdsec}/bin/cscli collections install crowdsecurity/caddy crowdsecurity/sshd crowdsecurity/linux || true'"
                "${pkgs.bash}/bin/bash -c '${pkgs.crowdsec}/bin/cscli bouncers add firewall -k $(cat /var/lib/crowdsec/bouncer-key) 2>/dev/null || true'"
              ];
            };
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
      })
    ]
  );
}
