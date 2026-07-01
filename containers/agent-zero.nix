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
    innerConfig = {
      virtualisation = {
        oci-containers.backend = "podman";
        podman.enable = true;
        oci-containers.containers.agent-zero = {
          image = "frdel/agent-zero:latest";
          ports = [ "50001:50001" ];
          environment = {
            A0_SET_CHAT_MODEL_PROVIDER = if cfg.vllmUrl != "" then "openai" else "ollama";
            A0_SET_CHAT_MODEL_NAME =
              if cfg.vllmUrl != "" then "meta-llama/Llama-3.1-8B-Instruct" else "llama3.1";
            A0_SET_UTILITY_MODEL_PROVIDER = if cfg.vllmUrl != "" then "openai" else "ollama";
            A0_SET_UTILITY_MODEL_NAME =
              if cfg.vllmUrl != "" then "meta-llama/Llama-3.1-8B-Instruct" else "llama3.1";
            A0_SET_EMBEDDING_MODEL_PROVIDER = if cfg.vllmUrl != "" then "openai" else "ollama";
            A0_SET_EMBEDDING_MODEL_NAME =
              if cfg.vllmUrl != "" then "text-embedding-3-small" else "nomic-embed-text";
          }
          // lib.optionalAttrs (cfg.ollamaUrl != "") {
            A0_SET_CHAT_MODEL_URL = cfg.ollamaUrl;
            A0_SET_UTILITY_MODEL_URL = cfg.ollamaUrl;
            A0_SET_EMBEDDING_MODEL_URL = cfg.ollamaUrl;
          }
          // lib.optionalAttrs (cfg.vllmUrl != "") {
            A0_SET_CHAT_MODEL_URL = cfg.vllmUrl;
            A0_SET_UTILITY_MODEL_URL = cfg.vllmUrl;
            A0_SET_EMBEDDING_MODEL_URL = cfg.vllmUrl;
          };

          environmentFiles = lib.optional (cfg.secretsFile != null) "/run/secrets/agent-zero.env";

          volumes = [
            "/var/lib/agent-zero/work_dir:/app/work_dir"
            "/var/lib/agent-zero/custom_python_scripts:/app/custom_python_scripts"
          ];

          cmd = [
            "python"
            "run_ui.py"
            "--port"
            "50001"
            "--host"
            "0.0.0.0"
          ];
        };
      };

      networking.firewall.allowedTCPPorts = [ 50001 ];
    };
    bindMounts = {
      "/var/lib/agent-zero" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    }
    // lib.optionalAttrs (cfg.secretsFile != null) {
      "/run/secrets/agent-zero.env" = {
        hostPath = cfg.secretsFile;
        isReadOnly = true;
      };
    };
  });
}
