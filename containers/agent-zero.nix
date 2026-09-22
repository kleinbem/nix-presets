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
          # UPDATED 2026-09-22: frdel/agent-zero:latest was confirmed dead
          # upstream 2026-08-05 (the tag started resolving to a bare Kali
          # base image, no application code at all). The project itself
          # is alive and actively maintained — it rebranded to
          # agent0ai/agent-zero (a v2.x rewrite), confirmed via its GitHub
          # org and Docker Hub: multi-arch (amd64+arm64), updated within
          # the last two weeks, versioned tags back to v1.11. Pinned to a
          # specific version rather than :latest since this is a fast-
          # moving v2.x line — bump deliberately, not implicitly.
          image = "agent0ai/agent-zero:v2.12";
          # Container's own default port is 80 (docker run -p 80:80 ...,
          # per the official install docs) — map to the fleet's existing
          # externalPort (inventory.nix) so nothing else needs to change.
          ports = [ "50001:80" ];
          # v2.x kept the same A0_SET_<setting>=<value> environment
          # override mechanism as the old image (confirmed via
          # knowledge/main/about/configuration.md and docs/setup/dev-setup.md
          # in the agent0ai/agent-zero repo) — just lowercase field names
          # now, matching usr/settings.json's own keys directly, and
          # *_api_base replaces the old *_URL suffix. No more custom `cmd`
          # override needed — that was a workaround for the broken Kali
          # image lacking a `python` symlink; this image's own entrypoint
          # starts the app correctly.
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

          # API key resolution (models.py's get_api_key) falls back to the
          # plain provider-named env var (OPENAI_API_KEY for the "openai"
          # provider used above) if present — same secretsFile mechanism
          # as before, just no A0-specific var name needed.
          environmentFiles = lib.optional (cfg.secretsFile != null) "/run/secrets/agent-zero.env";

          # v2.x consolidated onto one data path (was two: work_dir +
          # custom_python_scripts) — chats, memory, settings, and
          # everything else now live under /a0/usr.
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
