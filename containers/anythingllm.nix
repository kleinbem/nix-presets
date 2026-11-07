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
      description = "OpenAI-compatible LLM endpoint URL, without the /v1 suffix.";
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
    # Bundles the 15m pull timeout, nesting caps/devices, podman's own
    # registries.conf, and persistent podman image storage — see
    # factory.nix's usesPodman doc comment.
    usesPodman = true;
    innerConfig = {
      virtualisation = {
        oci-containers = {
          backend = "podman";
          containers.anythingllm = {
            # Release tag: :latest tracks master builds.
            image = "mintplexlabs/anythingllm:1.18.0"; # image-bump: semver
            ports = [ "3001:3001" ];
            volumes = [
              "/var/lib/anythingllm:/app/server/storage"
            ];
            environment = {
              STORAGE_DIR = "/app/server/storage";
              # --- AI Configuration ---
              # The native "openai" provider can't take a base URL, so LiteLLM
              # goes through the generic OpenAI-compatible one.
              LLM_PROVIDER = "generic-openai";
              GENERIC_OPEN_AI_BASE_PATH = "${lib.removeSuffix "/" cfg.llmUrl}/v1";
              GENERIC_OPEN_AI_API_KEY = "dummy";
              GENERIC_OPEN_AI_MODEL_PREF = cfg.modelName;
              GENERIC_OPEN_AI_MODEL_TOKEN_LIMIT = "4096";
              # AnythingLLM's defaults, pinned because nix-config's
              # vault-anythingllm-sync depends on them. No fleet service
              # serves embeddings, so this stays on the bundled CPU embedder.
              EMBEDDING_ENGINE = "native";
              VECTOR_DB = "lancedb";
            };
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
