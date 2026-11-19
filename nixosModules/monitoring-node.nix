{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.monitoring.node;
  textfileDir = "/run/prometheus-node-exporter-textfile";
  chrony = config.services.chrony;

  # node_exporter has no RTC collector, and node_timex_sync_status stays 0
  # under chrony's default rtcfile mode even when synced, so neither can tell
  # a wrong clock. nixos-nvme's RTC sat at 2021 for months unnoticed.
  timeMetrics = pkgs.writeShellScript "node-time-metrics" ''
    set -eu
    out=${textfileDir}/time.prom
    {
      # The RTC that /dev/rtc points at is the one the kernel and chrony use.
      rtc=$(${pkgs.coreutils}/bin/basename "$(${pkgs.coreutils}/bin/readlink -f /dev/rtc 2>/dev/null)" 2>/dev/null || true)
      if [ -n "$rtc" ] && [ -r "/sys/class/rtc/$rtc/since_epoch" ]; then
        name=$(${pkgs.coreutils}/bin/cat "/sys/class/rtc/$rtc/name")
        echo "# HELP node_rtc_offset_seconds RTC time minus system time."
        echo "# TYPE node_rtc_offset_seconds gauge"
        echo "node_rtc_offset_seconds{device=\"$rtc\",name=\"$name\"} $(( $(${pkgs.coreutils}/bin/cat "/sys/class/rtc/$rtc/since_epoch") - $(${pkgs.coreutils}/bin/date +%s) ))"
      fi
      ${lib.optionalString chrony.enable ''
        # CSV fields: 5 = system time offset, 14 = leap status.
        if t=$(${chrony.package}/bin/chronyc -c tracking 2>/dev/null); then
          echo "# HELP node_chrony_synchronized 1 when chrony's leap status is Normal."
          echo "# TYPE node_chrony_synchronized gauge"
          [ "$(echo "$t" | ${pkgs.coreutils}/bin/cut -d, -f14)" = Normal ] && echo "node_chrony_synchronized 1" || echo "node_chrony_synchronized 0"
          echo "# HELP node_chrony_system_offset_seconds Offset of the system clock from NTP time."
          echo "# TYPE node_chrony_system_offset_seconds gauge"
          echo "node_chrony_system_offset_seconds $(echo "$t" | ${pkgs.coreutils}/bin/cut -d, -f5)"
        fi
      ''}
    } > "$out.tmp"
    ${pkgs.coreutils}/bin/mv -f "$out.tmp" "$out"
  '';

  nixStoreMetrics = pkgs.writeShellScript "node-nix-store-metrics" ''
    set -eu
    out=${textfileDir}/nix_store.prom
    {
      paths=$(${pkgs.findutils}/bin/find /nix/store -maxdepth 1 -mindepth 1 | ${pkgs.coreutils}/bin/wc -l)
      roots=$(${config.nix.package}/bin/nix-store --gc --print-roots 2>/dev/null | ${pkgs.gnugrep}/bin/grep -c '^"' || true)
      gen=$(${pkgs.coreutils}/bin/readlink -f /nix/var/nix/profiles/system | ${pkgs.gnused}/bin/sed -n 's/.*system-\([0-9]*\)-link/\1/p')
      closure=$(${config.nix.package}/bin/nix --extra-experimental-features nix-command path-info -S /run/current-system 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $2}' || true)

      echo "# HELP nix_store_paths_total Total count of paths in /nix/store."
      echo "# TYPE nix_store_paths_total gauge"
      echo "nix_store_paths_total $paths"

      echo "# HELP nix_gc_roots_total Persistent GC roots holding store paths."
      echo "# TYPE nix_gc_roots_total gauge"
      echo "nix_gc_roots_total $roots"

      echo "# HELP nix_system_generation Current active NixOS system generation."
      echo "# TYPE nix_system_generation gauge"
      echo "nix_system_generation ''${gen:-0}"

      echo "# HELP nix_system_closure_bytes Closure size of /run/current-system in bytes."
      echo "# TYPE nix_system_closure_bytes gauge"
      echo "nix_system_closure_bytes ''${closure:-0}"
    } > "$out.tmp"
    ${pkgs.coreutils}/bin/mv -f "$out.tmp" "$out"
  '';
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
        "--collector.textfile.directory=${textfileDir}"
      ];
      port = 9100;
    };

    systemd = {
      tmpfiles.rules = [ "d ${textfileDir} 0755 root root - -" ];

      services.node-time-metrics = {
        description = "Write RTC and chrony metrics for node_exporter";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = timeMetrics;
          ReadWritePaths = [ textfileDir ];
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
        };
      };
      timers.node-time-metrics = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1min";
          OnUnitActiveSec = "5min";
        };
      };

      services.node-nix-store-metrics = {
        description = "Write Nix store metrics for node_exporter";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = nixStoreMetrics;
          ReadWritePaths = [ textfileDir ];
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
        };
      };
      timers.node-nix-store-metrics = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = "30min";
        };
      };
    };

    # Only open on NetBird (wt0)
    networking.firewall.interfaces."wt0".allowedTCPPorts = [ 9100 ];
  };
}
