_:
{ config, lib, myInventory, ... }:
let
  cfg = config.my.containers.falco;
  inv = myInventory;
in
{
  options.my.containers.falco = {
    enable = lib.mkEnableOption "Falco Runtime Security";
    ip = lib.mkOption { 
      type = lib.types.str;
      default = inv.network.nodes.falco.ip or "10.85.46.120";
    };
    sidekickIp = lib.mkOption {
      type = lib.types.str;
      default = inv.network.nodes.falcosidekick.ip or "10.85.46.121";
    };
    ntfyTopic = lib.mkOption {
      type = lib.types.str;
      default = "nixos-alerts-martin-$(hostname)";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers.containers = {
      # --- Falco Engine (The Scanner) ---
      falco = {
        image = "falcosecurity/falco:latest-debian";
        autoStart = true;
        extraOptions = [
          "--privileged"
          "--pid=host"
          "--ipc=host"
          "--net=cbr0"
          "--ip=${lib.head (lib.splitString "/" cfg.ip)}"
          "--security-opt=label=disable"
          "--security-opt=seccomp=unconfined"
          "--security-opt=apparmor=unconfined"
          "--ulimit=memlock=-1:-1"
          "--ulimit=nofile=8192:8192"
          # Direct Host Access (Required for eBPF and runtime monitoring)
          "--volume=/run/podman/podman.sock:/host/run/podman/podman.sock"
          "--volume=/dev:/host/dev:ro"
          "--volume=/proc:/host/proc:ro"
          "--volume=/etc:/host/etc:ro"
          "--volume=/sys:/host/sys:ro"
        ];
        environment = { };
        cmd = [
          "/usr/bin/falco"
          "-o" "engine.kind=modern_ebpf"
          "-o" "http_output.enabled=true"
          "-o" "http_output.url=http://${lib.head (lib.splitString "/" cfg.sidekickIp)}:2801"
        ];
      };

      # --- FalcoSidekick (The Alerter) ---
      falcosidekick = {
        image = "falcosecurity/falcosidekick:latest";
        autoStart = true;
        extraOptions = [
          "--net=cbr0"
          "--ip=${lib.head (lib.splitString "/" cfg.sidekickIp)}"
        ];
        environment = {
          # Route to Loki
          FALCOSIDEKICK_loki_hostport = "http://10.85.46.116:3100";
          # Route to ntfy
          FALCOSIDEKICK_ntfy_url = "https://ntfy.sh";
          FALCOSIDEKICK_ntfy_topic = cfg.ntfyTopic;
          # Settings
          FALCOSIDEKICK_loki_minimumpriority = "notice";
          FALCOSIDEKICK_ntfy_minimumpriority = "warning";
        };
      };
    };

    # Dependencies
    systemd.services.podman-falco = {
      after = [ "podman-network-cbr0.service" ];
      requires = [ "podman-network-cbr0.service" ];
    };
    systemd.services.podman-falcosidekick = {
      after = [ "podman-network-cbr0.service" ];
      requires = [ "podman-network-cbr0.service" ];
    };
  };
}
