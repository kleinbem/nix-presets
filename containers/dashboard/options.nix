{ lib }:
let
  tlsOpts = import ../../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.dashboard = {
    enable = lib.mkEnableOption "Home Dashboard Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostBridgeIp = lib.mkOption { type = lib.types.str; };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "1G";
    };
    caCertFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host path to the Caddy root CA, so health pings and widgets can verify the fleet's `tls internal` certificates.";
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path on the host to a .env file containing dashboard API keys";
    };
  }
  // tlsOpts;
}
