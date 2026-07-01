{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.anythingllm;
  inherit (self.lib) mkContainer;
in
{
  options.my.containers.anythingllm = {
    enable = lib.mkEnableOption "AnythingLLM Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    llmUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://litellm.internal";
      description = "OpenAI-compatible LLM endpoint URL.";
    };
    modelName = lib.mkOption {
      type = lib.types.str;
      default = "google/gemma-2b";
      description = "Default model name for AnythingLLM.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "2G";
    };
  };

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "anythingllm";
    inherit cfg;
    enableNesting = true; # Required for OCI-in-LXC
    innerConfig = {
      virtualisation.podman = {
        enable = true;
        dockerCompat = true;
      };

      virtualisation.oci-containers = {
        backend = "podman";
        containers.anythingllm = {
          image = "mintplexlabs/anythingllm:latest";
          ports = [ "3001:3001" ];
          volumes = [
            "/var/lib/anythingllm:/app/server/storage"
          ];
          environment = {
            STORAGE_DIR = "/app/server/storage";
            # --- AI Configuration ---
            LLM_PROVIDER = "openai";
            OPENAI_API_BASE = cfg.llmUrl;
            OPENAI_API_KEY = "dummy";
            FREE_MODEL_NAME = cfg.modelName;
            FREE_MODEL_MAX_TOKENS = "4096";
          };
        };
      };

      networking.firewall.allowedTCPPorts = [ 3001 ];
    };
    bindMounts = {
      "/var/lib/anythingllm" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    };
  });
}
