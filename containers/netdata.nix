_:
{ config, lib, myInventory, ... }:
let
  cfg = config.my.containers.netdata;
  inv = myInventory;
in
{
  options.my.containers.netdata = {
    enable = lib.mkEnableOption "Netdata Real-time Telemetry";
    ip = lib.mkOption { 
      type = lib.types.str;
      default = inv.network.nodes.netdata.ip or "10.85.46.122";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers.containers.netdata = {
      image = "netdata/netdata:latest";
      autoStart = true;
      extraOptions = [
        "--privileged"
        "--net=cbr0"
        "--ip=${lib.head (lib.splitString "/" cfg.ip)}"
        "--security-opt=label=disable"
        # Host access for telemetry
        "--volume=netdataconfig:/etc/netdata"
        "--volume=netdatalib:/var/lib/netdata"
        "--volume=netdatacache:/var/cache/netdata"
        "--volume=/:/host/root:ro"
        "--volume=/etc/passwd:/host/etc/passwd:ro"
        "--volume=/etc/group:/host/etc/group:ro"
        "--volume=/proc:/host/proc:ro"
        "--volume=/sys:/host/sys:ro"
        "--volume=/etc/os-release:/host/etc/os-release:ro"
        "--volume=/var/run/podman/podman.sock:/var/run/podman/podman.sock"
      ];
      environment = {
        NETDATA_HOSTNAME = config.networking.hostName;
      };
    };

    # Dependencies
    systemd.services.podman-netdata = {
      after = [ "podman-network-cbr0.service" ];
      requires = [ "podman-network-cbr0.service" ];
    };
  };
}
