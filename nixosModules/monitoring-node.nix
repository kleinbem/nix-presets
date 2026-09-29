{ config, lib, ... }:
let
  cfg = config.my.monitoring.node;
in
{
  options.my.monitoring.node = {
    enable = lib.mkEnableOption "Node Exporter for fleet-wide monitoring";
  };

  config = lib.mkIf cfg.enable {
    services.prometheus.exporters.node = {
      enable = true;
      enabledCollectors = [
        "systemd"
        "processes"
      ];
      extraFlags = [
        "--collector.systemd.enable-restarts-metrics"
        "--collector.systemd.enable-start-time-metrics"
      ];
      port = 9100;
    };

    # Only open on NetBird (wt0)
    networking.firewall.interfaces."wt0".allowedTCPPorts = [ 9100 ];
  };
}
