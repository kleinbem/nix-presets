{ config, pkgs, ... }:

{
  virtualisation.waydroid.enable = true;

  # networking.firewall.allowedTCPPorts = [ 53317 ]; # Example port if needed, usually container handles NAT
  # networking.firewall.allowedUDPPorts = [ 53317 ];
}
