{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.loki;
  inherit (self.lib) mkContainer;
in
{
  options.my.containers.loki = {
    enable = lib.mkEnableOption "Loki Log Aggregator Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "1G";
    };
  };

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "loki";
    inherit cfg;
    innerConfig = {
      services.loki = {
        enable = true;
        configFile = pkgs.writeText "loki.yaml" (
          builtins.toJSON {
            auth_enabled = false;
            server = {
              http_listen_port = 3100;
            };
            common = {
              instance_addr = "127.0.0.1";
              path_prefix = "/var/lib/loki";
              storage = {
                filesystem = {
                  chunks_directory = "/var/lib/loki/chunks";
                  rules_directory = "/var/lib/loki/rules";
                };
              };
              replication_factor = 1;
              ring = {
                kvstore = {
                  store = "inmemory";
                };
              };
            };
            schema_config = {
              configs = [
                {
                  from = "2020-10-24";
                  store = "tsdb";
                  object_store = "filesystem";
                  schema = "v13";
                  index = {
                    prefix = "index_";
                    period = "24h";
                  };
                }
              ];
            };
          }
        );
      };

      networking.firewall.allowedTCPPorts = [ 3100 ];
    };
    bindMounts = {
      "/var/lib/loki" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    };
  });
}
