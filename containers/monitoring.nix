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
    githubMetrics = {
      enable = lib.mkEnableOption "GitHub Actions metrics (prometheus-json-exporter scraping the GitHub API)";
      repos = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "kleinbem/nix" ];
        description = "owner/repo list to scrape (runner + run-count metrics per repo).";
      };
      configFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "json-exporter config (module mappings + GitHub API bearer token). Provide via a sops template so the PAT stays encrypted.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 7979;
      };
      scrapeInterval = lib.mkOption {
        type = lib.types.str;
        default = "60s";
      };
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
                uid = "victoriametrics";
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
            dashboards.settings.providers = lib.mkIf cfg.githubMetrics.enable [
              {
                name = "github-actions";
                options.path = ./grafana-dashboards;
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

        # GitHub Actions metrics: json-exporter scrapes the GitHub REST API
        # (config + bearer token come from cfg.githubMetrics.configFile, bind-mounted).
        prometheus.exporters.json = lib.mkIf cfg.githubMetrics.enable {
          enable = true;
          inherit (cfg.githubMetrics) port;
          configFile = "/etc/json-exporter.yml";
        };
      };

      environment.etc = {
        # JSON is valid YAML, so we render the scrape config with toJSON to avoid
        # hand-indented heredoc YAML (esp. the json-exporter probe jobs).
        "vmagent/scrape.yml".text = builtins.toJSON {
          scrape_configs = [
            {
              job_name = "node-exporters";
              static_configs = [ { targets = map (t: "${t}:9100") cfg.nodeTargets; } ];
            }
            {
              job_name = "vllm";
              static_configs = [ { targets = map (t: "${t}:8000") cfg.vllmTargets; } ];
            }
            {
              job_name = "ollama";
              static_configs = [ { targets = map (t: "${t}:11434") cfg.ollamaTargets; } ];
            }
          ]
          ++ lib.optionals cfg.githubMetrics.enable (
            let
              # blackbox-style probe: VM passes the GitHub URL as ?target=, json-exporter
              # fetches it (with the bearer token from its config) and returns metrics.
              relabel = [
                {
                  source_labels = [ "__address__" ];
                  target_label = "__param_target";
                }
                {
                  target_label = "__address__";
                  replacement = "localhost:${toString cfg.githubMetrics.port}";
                }
              ];
              ghJob = name: module: url: extraLabels: {
                job_name = name;
                metrics_path = "/probe";
                params.module = [ module ];
                scrape_interval = cfg.githubMetrics.scrapeInterval;
                static_configs = [
                  {
                    targets = [ url ];
                    labels = extraLabels;
                  }
                ];
                relabel_configs = relabel;
              };
            in
            lib.concatMap (repo: [
              (ghJob "gh-runners-${repo}" "runners" "https://api.github.com/repos/${repo}/actions/runners" {
                inherit repo;
              })
              (ghJob "gh-runs-queued-${repo}" "runs_count"
                "https://api.github.com/repos/${repo}/actions/runs?status=queued"
                {
                  inherit repo;
                  run_status = "queued";
                }
              )
              (ghJob "gh-runs-inprogress-${repo}" "runs_count"
                "https://api.github.com/repos/${repo}/actions/runs?status=in_progress"
                {
                  inherit repo;
                  run_status = "in_progress";
                }
              )
            ]) cfg.githubMetrics.repos
          );
        };

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
    }
    // lib.optionalAttrs (cfg.githubMetrics.enable && cfg.githubMetrics.configFile != null) {
      "/etc/json-exporter.yml" = {
        hostPath = cfg.githubMetrics.configFile;
        isReadOnly = true;
      };
    };
  });
}
