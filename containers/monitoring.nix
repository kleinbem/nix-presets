{ self }:
{ config, lib, ... }:
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
  };

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "monitoring";
    inherit cfg;
    innerConfig = {
      services.victoriametrics = {
        enable = true;
        listenAddress = ":8428";
        extraOptions = [
          "-promscrape.config=/etc/vmagent/scrape.yml"
          "-storageDataPath=/var/lib/victoria-metrics"
        ];
      };

      environment.etc."vmagent/scrape.yml".text = ''
        scrape_configs:
          - job_name: 'node-exporters'
            static_configs:
              - targets: ${builtins.toJSON (map (t: "${t}:9100") cfg.nodeTargets)}
          - job_name: 'vllm'
            static_configs:
              - targets: ${builtins.toJSON (map (t: "${t}:8000") cfg.vllmTargets)}
      '';

      services.grafana = {
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

      networking.firewall.allowedTCPPorts = [
        3000
        8428
      ];
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
