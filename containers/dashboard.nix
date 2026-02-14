{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.my.containers.dashboard;
in
{
  options.my.containers.dashboard = {
    enable = lib.mkEnableOption "Dashboard Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostBridge = lib.mkOption {
      type = lib.types.str;
      default = "incusbr0";
    };
    hostBridgeIp = lib.mkOption {
      type = lib.types.str;
      description = "IP of the host on the bridge (for accessing host services)";
    };
    # Note: We are currently hardcoding the other container IPs in the widgets below.
    # In a fully ideal setup, these would also be options.
    hostName = lib.mkOption {
      type = lib.types.str;
      default = "dashboard";
    };
  };

  config = lib.mkIf cfg.enable {
    containers.dashboard = {
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

          services.homepage-dashboard = {
            enable = true;
            listenPort = 8082;
            openFirewall = true;
            allowedHosts = "*";
          };

          systemd.services.homepage-dashboard.serviceConfig = {
            # Zero Trust Hardening
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectKernelTunables = true;
            ProtectControlGroups = true;
            RestrictSUIDSGID = true;
            RemoveIPC = true;
            NoNewPrivileges = true;
            RestrictRealtime = true;
            MemoryDenyWriteExecute = true;
            SupplementaryGroups = [ "docker" ];
          };
          users.groups.docker.gid = 131;

          services.homepage-dashboard = {
            settings = {
              allowed_hosts = [ "*" ];
              remote = true;
              background = {
                image = "background.png";
              };
              layout = {
                "System" = {
                  style = "row";
                  columns = 4;
                };
                "Automation" = {
                  style = "row";
                  columns = 2;
                };
                "Development" = {
                  style = "row";
                  columns = 4;
                };
                "AI" = {
                  style = "row";
                  columns = 2;
                };
              };
            };

            widgets = [
              {
                search = {
                  provider = "google";
                  target = "_blank";
                  url = "https://google.ie";
                };
              }
              {
                openmeteo = {
                  label = "Watergrasshill";
                  latitude = 52.02;
                  longitude = -8.34;
                  timezone = "Europe/Dublin";
                  units = "metric";
                };
              }
              {
                resources = {
                  cpu = true;
                  memory = true;
                  disk = "/";
                };
              }
              {
                glances = {
                  url = "http://${cfg.hostBridgeIp}:61208";
                  label = "System";
                  version = 4;
                  proxied = true;
                  metric = [
                    "cpu"
                    "memory"
                    "disk"
                  ];
                };
              }
              {
                datetime = {
                  format = {
                    date = "dddd, MMMM Do YYYY";
                    time = "HH:mm";
                  };
                };
              }
            ];

            services = [
              {
                "System" = [
                  {
                    "Cockpit" = {
                      href = "http://${cfg.hostBridgeIp}:9091";
                      description = "System Management";
                      icon = "cockpit.png";
                    };
                  }
                  {
                    "Incus" = {
                      href = "https://${cfg.hostBridgeIp}:8443";
                      description = "System Containers";
                      icon = "incus.png";
                    };
                  }
                  {
                    "CUPS" = {
                      href = "http://${cfg.hostBridgeIp}:631";
                      description = "Printer Management";
                      icon = "cups.png";
                    };
                  }
                ];
              }
              {
                "Automation" = [
                  {
                    "n8n" = {
                      href = "http://10.85.46.99:5678";
                      description = "Workflow Automation";
                      icon = "n8n.png";
                    };
                  }
                ];
              }
              {
                "Development" = [
                  {
                    "Code Server" = {
                      href = "http://10.85.46.101:4444";
                      description = "VS Code Web";
                      icon = "vscode.png";
                    };
                  }
                  {
                    "SilverBullet" = {
                      href = "http://10.85.46.100:3333";
                      description = "Notes & Knowledge Base";
                      icon = "silverbullet.png";
                    };
                  }
                ];
              }
              {
                "AI" = [
                  {
                    "n8n" = {
                      href = "http://10.85.46.99:5678";
                      description = "Workflow Automation";
                      icon = "n8n.png";
                    };
                  }
                ];
              }
              {
                "AI" = [
                  {
                    "Open WebUI" = {
                      href = "http://10.85.46.102:8080";
                      description = "LLM Chat";
                      icon = "si-openwebui";
                    };
                  }
                  {
                    "Ollama" = {
                      href = "http://${cfg.hostBridgeIp}:11434";
                      description = "LLM Backend";
                      icon = "ollama.png";
                    };
                  }
                ];
              }
            ];

            bookmarks = [
              {
                "Developer" = [
                  {
                    "GitHub" = [
                      {
                        abbr = "GH";
                        href = "https://github.com";
                      }
                    ];
                  }
                ];
              }
            ];
          };

          system.stateVersion = "25.11";
        };

      bindMounts = {
        "/var/run/docker.sock" = {
          hostPath = "/var/run/docker.sock";
          isReadOnly = true;
        };
      };
    };
  };
}
