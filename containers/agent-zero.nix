{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.agent-zero;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };

  useOllama = cfg.ollamaUrl != "";
  apiBase = if useOllama then cfg.ollamaUrl else cfg.vllmUrl;
  provider = if useOllama then "ollama" else "openai";
  chatModel = if useOllama then "llama3.1" else "meta-llama/Llama-3.1-8B-Instruct";
  llmSlot = {
    inherit provider;
    name = chatModel;
    api_base = apiBase;
    ctx_length = 128000;
    rl_requests = 0;
    rl_input = 0;
    rl_output = 0;
    kwargs = { };
  };
  defaultPreset = {
    name = "Default";
    chat = llmSlot // {
      ctx_history = 0.7;
      vision = false;
    };
    utility = llmSlot // {
      ctx_input = 0.7;
    };
    embedding = {
      inherit provider;
      name = if useOllama then "nomic-embed-text" else "text-embedding-3-small";
      api_base = apiBase;
      rl_requests = 0;
      rl_input = 0;
      kwargs = { };
    };
  };
  # The script replaces and selects "Default", so the name is fixed.
  presetFile = pkgs.writeText "agent-zero-default-preset.json" (
    builtins.toJSON (cfg.modelPreset // { name = "Default"; })
  );

  # v2.x reads models only from the _model_config presets, not env vars.
  # Replace just Default so presets added in the UI survive.
  writeModelPreset = pkgs.writeShellApplication {
    name = "agent-zero-model-preset";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.yq-go
    ];
    text = ''
      usr=$1
      dir=$usr/plugins/_model_config
      mkdir -p "$dir"
      presets=$dir/presets.yaml
      if [ -s "$presets" ] && yq -e 'tag == "!!seq"' "$presets" >/dev/null 2>&1; then
        yq -i -P '[load("${presetFile}")] + map(select((.name // "" | downcase) != "default"))' "$presets"
      else
        if [ -e "$presets" ]; then mv "$presets" "$presets.pre-nix.bak"; fi
        yq -P -o yaml '[.]' ${presetFile} > "$presets"
      fi

      # A missing or pre-preset config.json makes the startup migration
      # rebuild Default from legacy settings, so pin it to a selection.
      conf=$dir/config.json
      if ! [ -s "$conf" ] || yq -p json -e \
        'has("chat_model") or has("utility_model") or has("embedding_model")' "$conf" >/dev/null 2>&1; then
        if [ -e "$conf" ]; then mv "$conf" "$conf.pre-nix.bak"; fi
        echo '{"model_preset": "Default"}' > "$conf"
      fi
      chown -R --reference="$usr" "$dir"
    '';
  };

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
      description = "URL of the vLLM/OpenAI API endpoint; used when ollamaUrl is empty.";
    };
    modelPreset = lib.mkOption {
      type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
      default = if cfg.ollamaUrl == "" && cfg.vllmUrl == "" then null else defaultPreset;
      defaultText = lib.literalMD "Llama 3.1 via `ollamaUrl` (preferred when set) or `vllmUrl`";
      description = ''
        Agent Zero's "Default" model preset (chat/utility/embedding), written into
        usr/plugins/_model_config/presets.yaml before every start. UI edits to other
        presets survive; edits to Default are replaced. The name is always "Default";
        null leaves presets alone.
      '';
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
          image = "agent0ai/agent-zero:v2.15"; # image-bump: semver
          # The app listens on 80; 50001 is the fleet's externalPort in inventory.nix.
          ports = [ "50001:80" ];
          # The app reads the provider's plain env var (OPENAI_API_KEY for "openai").
          environmentFiles = lib.optional (cfg.secretsFile != null) "/run/secrets/agent-zero.env";

          # Chats, memory and settings all live under /a0/usr.
          volumes = [ "/var/lib/agent-zero/usr:/a0/usr" ];
        };
      };

      systemd.services.podman-agent-zero.preStart = lib.mkIf (cfg.modelPreset != null) (
        lib.mkBefore "${lib.getExe writeModelPreset} /var/lib/agent-zero/usr"
      );

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
