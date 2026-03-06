# tls-options.nix — Reusable TLS option submodule for container presets.
# Import this in any container module that supports mTLS sidecar.
{ lib }:
{
  tls = {
    enable = lib.mkEnableOption "mTLS sidecar proxy for this container";
    serverPort = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "The plain-HTTP service port to wrap with TLS (0 = no inbound sidecar).";
    };
    upstreams = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            target = lib.mkOption {
              type = lib.types.str;
              description = "IP of the upstream container.";
            };
            port = lib.mkOption {
              type = lib.types.int;
              default = 443;
              description = "Port on the upstream (usually 443 for mTLS).";
            };
          };
        }
      );
      default = [ ];
      description = "List of upstream containers to connect to via mTLS.";
    };
  };
}
