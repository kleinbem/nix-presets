{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.litellm;
  inherit (self.lib) mkContainer;
in
{
  options.my.containers.litellm = {
    enable = lib.mkEnableOption "LiteLLM Proxy NixOS Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "2G";
    };
    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    backends = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            url = lib.mkOption { type = lib.types.str; };
            model = lib.mkOption { type = lib.types.str; };
          };
        }
      );
      default = [ ];
    };
  }
  // import ../lib/tls-options.nix { inherit lib; };

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "litellm";
    inherit cfg;
    innerConfig = {
      # 1. Custom LiteLLM Service Block
      systemd.services.litellm = {
        description = "LiteLLM API Proxy";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];
        environment = {
          LITELLM_CONFIG_PATH = "/etc/litellm/config.yaml";
        };
        serviceConfig = {
          ExecStart = "${pkgs.litellm}/bin/litellm --config /etc/litellm/config.yaml --port 4000 --host 0.0.0.0";
          Restart = "always";
          User = "litellm";
          Group = "litellm";
          EnvironmentFile = lib.optional (cfg.secretsFile != null) "/run/secrets/litellm.env";
        };
      };

      users.users.litellm = {
        isSystemUser = true;
        group = "litellm";
      };
      users.groups.litellm = { };

      # 2. Config Generation
      environment.etc."litellm/config.yaml".text = builtins.toJSON {
        model_list = map (b: {
          model_name = b.name;
          litellm_params = {
            inherit (b) model;
            api_base = b.url;
            api_key = "sk-placeholder";
          };
        }) cfg.backends;
        router_settings = {
          routing_strategy = "latency-based-routing";
          enable_pre_call_checks = true;
        };
        general_settings = {
          master_key = "sk-1234";
        };
      };

      networking.firewall.allowedTCPPorts = [ 4000 ];
    };

    # Bind-mount secrets and data
    bindMounts =
      (lib.optionalAttrs (cfg.secretsFile != null) {
        "/run/secrets/litellm.env" = {
          hostPath = cfg.secretsFile;
          isReadOnly = true;
        };
      })
      // {
        "/var/lib/litellm" = {
          hostPath = cfg.hostDataDir;
          isReadOnly = false;
        };
      };
  });
}
