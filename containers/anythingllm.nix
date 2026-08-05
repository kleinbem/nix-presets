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
    # Default 90s TimeoutStartSec kills the container mid-pull before its
    # (large, multi-hundred-MB) docker image finishes downloading —
    # confirmed live 2026-08-05: repeated restarts in a row, never
    # converging. Same fix monitoring.nix already needed for its own
    # (native, not podman-pulled) heavier startup.
    timeout = "15m";
    enableNesting = true; # Required for OCI-in-LXC
    innerConfig = {
      virtualisation.podman = {
        enable = true;
        dockerCompat = true;
      };

      # Podman inside this nspawn container has its own registries.conf,
      # separate from whatever the outer host configures — without this, a
      # short/unqualified image name like "mintplexlabs/anythingllm:latest"
      # (below) fails to pull outright ("no unqualified-search registries
      # are defined"). Confirmed live 2026-08-05: this had never actually
      # worked on any host before, 0 bytes of ever-persisted state proved
      # it.
      virtualisation.containers.registries.settings.unqualified-search-registries = [
        "docker.io"
      ];

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
