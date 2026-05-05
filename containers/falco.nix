{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.falco;
  inherit (self.lib) mkContainer;
in
{
  options.my.containers.falco = {
    enable = lib.mkEnableOption "Falco Native Security Stack";
    ip = lib.mkOption {
      type = lib.types.str;
      default = "10.85.46.120/24";
    };
    sidekickIp = lib.mkOption {
      type = lib.types.str;
      default = "10.85.46.121/24";
    };
    ntfyTopic = lib.mkOption {
      type = lib.types.str;
      default = "nixos-alerts-martin";
    };
  };

  config = lib.mkIf cfg.enable {
    # --- 1. Falco Engine Container ---
    # Note: We merge the results of two mkContainer calls by manually defining the containers
    # and using the common logic.

    # Falco Container (Sensor)
    containers.falco =
      (mkContainer {
        inherit config;
        name = "falco";
        cfg = {
          inherit (cfg) ip;
          autoStart = true;
        };

        # Level 10 Privileges: Required for eBPF and kernel monitoring
        additionalCapabilities = [
          "CAP_SYS_ADMIN"
          "CAP_SYS_RESOURCE"
          "CAP_NET_RAW"
          "CAP_NET_ADMIN"
          "CAP_SYS_PTRACE"
        ];

        innerConfig =
          { pkgs, ... }:
          let
            # Inline Falco config — no nixpkgs module exists for services.falco
            falcoConfig = pkgs.writeText "falco.yaml" (
              builtins.toJSON {
                json_output = true;
                engine = {
                  kind = "modern_ebpf";
                };
                http_output = {
                  enabled = true;
                  url = "http://${cfg.sidekickIp}:2801";
                };
                rules_files = [
                  "/etc/falco/falco_rules.yaml"
                  "/etc/falco/falco_rules.local.yaml"
                ];
                stdout_output = {
                  enabled = true;
                };
                syslog_output = {
                  enabled = false;
                };
                log_level = "info";
              }
            );
          in
          {
            environment.systemPackages = [ pkgs.falco ];

            systemd.services.falco = {
              description = "Falco Runtime Security Engine";
              after = [ "network.target" ];
              wantedBy = [ "multi-user.target" ];

              serviceConfig = {
                Type = "simple";
                ExecStart = "${pkgs.falco}/bin/falco -c ${falcoConfig}";
                Restart = "on-failure";
                RestartSec = "5s";
              };
            };
          };

        bindMounts = {
          "/dev" = {
            hostPath = "/dev";
            isReadOnly = true;
          };
          "/proc" = {
            hostPath = "/proc";
            isReadOnly = true;
          };
          "/sys" = {
            hostPath = "/sys";
            isReadOnly = true;
          };
          "/etc/os-release" = {
            hostPath = "/etc/os-release";
            isReadOnly = true;
          };
        };
      }).containers.falco;

    # Falcosidekick Container (Alerter)
    containers.falcosidekick =
      (mkContainer {
        inherit config;
        name = "falcosidekick";
        cfg = {
          ip = cfg.sidekickIp;
          autoStart = true;
        };

        innerConfig =
          { pkgs, ... }:
          let
            # Inline Falcosidekick config — no nixpkgs module exists for services.falcosidekick
            sidekickConfig = pkgs.writeText "falcosidekick-config.yaml" (
              builtins.toJSON {
                listenaddress = "0.0.0.0";
                listenport = 2801;
                loki = {
                  hostport = "http://10.85.46.116:3100";
                  minimumpriority = "notice";
                };
                ntfy = {
                  url = "https://ntfy.sh";
                  topic = cfg.ntfyTopic;
                  minimumpriority = "warning";
                };
              }
            );
          in
          {
            environment.systemPackages = [ pkgs.falcosidekick ];

            systemd.services.falcosidekick = {
              description = "Falcosidekick Alert Router";
              after = [ "network.target" ];
              wantedBy = [ "multi-user.target" ];

              serviceConfig = {
                Type = "simple";
                ExecStart = "${pkgs.falcosidekick}/bin/falcosidekick -c ${sidekickConfig}";
                Restart = "on-failure";
                RestartSec = "5s";
              };
            };

            networking.firewall.allowedTCPPorts = [ 2801 ];
          };
      }).containers.falcosidekick;
  };
}
