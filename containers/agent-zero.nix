{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.agent-zero;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };

in
{
  options.my.containers.agent-zero = {
    enable = lib.mkEnableOption "Agent Zero AI Framework Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    ollamaUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "URL of the Ollama API endpoint.";
    };
    vllmUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://litellm.internal";
      description = "URL of the vLLM/OpenAI API endpoint.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "4G";
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path on the host to environment file containing API keys (e.g. OPENAI_API_KEY).";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "agent-zero";
    inherit cfg;
    # Bundles the 15m pull timeout, nesting caps/devices, podman's own
    # registries.conf, and persistent podman image storage — see
    # factory.nix's usesPodman doc comment.
    usesPodman = true;
    # Bind-mounts to /run/secrets/agent-zero.env — see factory.nix's
    # secretsFile doc comment.
    inherit (cfg) secretsFile;
    innerConfig = {
      virtualisation = {
        oci-containers.backend = "podman";
        oci-containers.containers.agent-zero = {
          # Pinned, not :latest: v2.x moves fast, so bump deliberately.
          image = "agent0ai/agent-zero:v2.12";
          # The app listens on 80; 50001 is the fleet's externalPort in inventory.nix.
          ports = [ "50001:80" ];
          # A0_SET_<key> overrides usr/settings.json; keys are its lowercase field names.
          environment = {
            A0_SET_chat_model_provider = if cfg.vllmUrl != "" then "openai" else "ollama";
            A0_SET_chat_model_name =
              if cfg.vllmUrl != "" then "meta-llama/Llama-3.1-8B-Instruct" else "llama3.1";
            A0_SET_utility_model_provider = if cfg.vllmUrl != "" then "openai" else "ollama";
            A0_SET_utility_model_name =
              if cfg.vllmUrl != "" then "meta-llama/Llama-3.1-8B-Instruct" else "llama3.1";
            A0_SET_embedding_model_provider = if cfg.vllmUrl != "" then "openai" else "ollama";
            A0_SET_embedding_model_name =
              if cfg.vllmUrl != "" then "text-embedding-3-small" else "nomic-embed-text";
          }
          // lib.optionalAttrs (cfg.ollamaUrl != "") {
            A0_SET_chat_model_api_base = cfg.ollamaUrl;
            A0_SET_utility_model_api_base = cfg.ollamaUrl;
            A0_SET_embedding_model_api_base = cfg.ollamaUrl;
          }
          // lib.optionalAttrs (cfg.vllmUrl != "") {
            A0_SET_chat_model_api_base = cfg.vllmUrl;
            A0_SET_utility_model_api_base = cfg.vllmUrl;
            A0_SET_embedding_model_api_base = cfg.vllmUrl;
          };

          # The app reads the provider's plain env var (OPENAI_API_KEY for "openai").
          environmentFiles = lib.optional (cfg.secretsFile != null) "/run/secrets/agent-zero.env";

          # Chats, memory and settings all live under /a0/usr.
          volumes = [ "/var/lib/agent-zero/usr:/a0/usr" ];
        };
      };

      networking.firewall.allowedTCPPorts = [ 50001 ];
    };
    bindMounts = {
      "/var/lib/agent-zero" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    };
  });
}
