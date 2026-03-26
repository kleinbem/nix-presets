_:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.litellm;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.litellm = {
    enable = lib.mkEnableOption "LiteLLM Proxy Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "2G";
    };
    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Start the container automatically on boot.";
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path on the host to environment file containing MASTER_KEY etc.";
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
    enableNesting = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Allow nesting OCI containers (Podman) inside this container.";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable {
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

    virtualisation.oci-containers.containers.litellm = {
      image = "ghcr.io/berriai/litellm:main-latest";
      inherit (cfg) autoStart;
      ports = [
        "4000:4000"
      ];
      volumes = [
        "/etc/litellm/config.yaml:/app/config.yaml:ro"
        "${cfg.hostDataDir}:/app/data"
      ];
      environmentFiles = lib.optional (cfg.secretsFile != null) cfg.secretsFile;
      cmd = [
        "--config"
        "/app/config.yaml"
        "--port"
        "4000"
        "--host"
        "0.0.0.0"
      ];
      extraOptions = [
        "--net=cbr0"
        "--ip=${lib.head (lib.splitString "/" cfg.ip)}"
        "--cap-drop=all"
        "--security-opt=no-new-privileges"
      ];
    };

    systemd.services.podman-litellm = {
      after = [ "podman-network-cbr0.service" ];
      requires = [ "podman-network-cbr0.service" ];
      serviceConfig = {
        MemoryMax = lib.mkIf (cfg.memoryLimit != null) cfg.memoryLimit;
        Environment = [ "TMPDIR=/var/lib/images/podman/tmp" ];
      };
    };
  };
}
