{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.monitoring;
  inherit (self.lib) mkContainer;
in
{
  options.my.containers.monitoring = {
    enable = lib.mkEnableOption "Centralized Monitoring (VictoriaMetrics + Grafana)";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    nodeTargets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "10.85.46.1" ];
      description = "List of node IPs to scrape for metrics.";
    };
    vllmTargets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "List of vLLM IPs to scrape for metrics.";
    };
    ollamaTargets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "List of Ollama container IPs to scrape for metrics.";
    };
  };

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "monitoring";
    inherit cfg;
    timeout = "5m";
    innerConfig = {
      services = {
        victoriametrics = {
          enable = true;
          listenAddress = ":8428";
          extraOptions = [
            "-promscrape.config=/etc/vmagent/scrape.yml"
            "-storageDataPath=/var/lib/victoria-metrics"
          ];
        };

        grafana = {
          enable = true;
          settings = {
            server.http_port = 3000;
            security.secret_key = "antigravity-monitoring-key-2026";
          };
          provision = {
            enable = true;
            datasources.settings.datasources = [
              {
                name = "VictoriaMetrics";
                type = "prometheus";
                url = "http://localhost:8428";
                isDefault = true;
              }
              {
                name = "Loki";
                type = "loki";
                url = "http://10.85.46.116:3100";
              }
            ];
          };
        };

        prometheus.alertmanager = {
          enable = true;
          port = 9093;
          configuration = {
            route = {
              receiver = "default";
              group_by = [ "alertname" ];
              group_wait = "30s";
              group_interval = "5m";
              repeat_interval = "12h";
            };
            receivers = [
              {
                name = "default";
              }
            ];
          };
        };
      };

      environment.etc = {
        "vmagent/scrape.yml".text = ''
          scrape_configs:
            - job_name: 'node-exporters'
              static_configs:
                - targets: ${builtins.toJSON (map (t: "${t}:9100") cfg.nodeTargets)}
            - job_name: 'vllm'
              static_configs:
                - targets: ${builtins.toJSON (map (t: "${t}:8000") cfg.vllmTargets)}
            - job_name: 'ollama'
              static_configs:
                - targets: ${builtins.toJSON (map (t: "${t}:11434") cfg.ollamaTargets)}
        '';

        "vmalert/rules.yml".text = ''
          groups:
            - name: system-health
              rules:
                - alert: HostDown
                  expr: up == 0
                  for: 2m
                  labels:
                    severity: critical
                  annotations:
                    summary: "Host {{ $labels.instance }} is down"
                    description: "Target has been unresponsive for more than 2 minutes."
                - alert: HighDiskUsage
                  expr: 'node_filesystem_free_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} * 100 < 15'
                  for: 5m
                  labels:
                    severity: warning
                  annotations:
                    summary: "High disk usage on {{ $labels.instance }}"
                    description: "Disk space on / has fallen below 15% for more than 5 minutes."
        '';
      };

      systemd.services = {
        vmalert = {
          description = "vmalert service";
          wantedBy = [ "multi-user.target" ];
          after = [
            "network.target"
            "victoriametrics.service"
          ];
          serviceConfig = {
            DynamicUser = true;
            Restart = "on-failure";
            ExecStart = "${pkgs.victoriametrics}/bin/vmalert -datasource.url=http://localhost:8428 -notifier.url=http://localhost:9093 -rule=/etc/vmalert/rules.yml";
            ExecReload = "${pkgs.coreutils}/bin/kill -SIGHUP $MAINPID";
          };
        };

        victoriametrics = {
          serviceConfig = {
            DynamicUser = lib.mkForce false;
            User = "victoriametrics";
            Group = "victoriametrics";
            ExecStartPre = [
              "+${pkgs.coreutils}/bin/chown -R victoriametrics:victoriametrics /var/lib/victoria-metrics"
            ];
          };
        };

        grafana = {
          serviceConfig.ExecStartPre = [
            "+${pkgs.coreutils}/bin/chown -R grafana:grafana /var/lib/grafana"
          ];
        };
      };

      networking.firewall.allowedTCPPorts = [
        3000
        8428
        9093
      ];

      users = {
        users.victoriametrics = {
          isSystemUser = true;
          group = "victoriametrics";
        };
        groups.victoriametrics = { };
      };
    };
    bindMounts = {
      "/var/lib/victoria-metrics" = {
        hostPath = "${cfg.hostDataDir}/db";
        isReadOnly = false;
      };
      "/var/lib/grafana" = {
        hostPath = "${cfg.hostDataDir}/grafana";
        isReadOnly = false;
      };
    };
  });
}
