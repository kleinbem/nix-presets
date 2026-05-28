{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.attic;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.attic = {
    enable = lib.mkEnableOption "Attic Binary Cache Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path to environment file containing ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64";
    };
    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "attic";
    inherit cfg;
    innerConfig = _: {
      services.atticd = {
        enable = true;
        environmentFile = if cfg.secretsFile != null then "/etc/atticd-env" else null;
        settings = {
          listen = "[::]:8080";
          api-endpoint = "http://cache.kleinbem.dev/"; # Configured for HTTP to avoid local cert issues
          storage = {
            type = "local";
            path = "/var/lib/atticd/storage";
          };
          chunking = {
            nar-size-threshold = 65536;
            min-size = 16384;
            avg-size = 65536;
            max-size = 262144;
          };
        };
      };

      systemd.services.atticd.serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = lib.mkForce "root";
        Group = lib.mkForce "root";
      };

      networking.firewall.allowedTCPPorts = [ 8080 ];
    };
    bindMounts = {
      "/var/lib/atticd" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    }
    // lib.optionalAttrs (cfg.secretsFile != null) {
      "/etc/atticd-env" = {
        hostPath = cfg.secretsFile;
        isReadOnly = true;
      };
    };
  });
}
