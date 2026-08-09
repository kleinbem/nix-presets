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
      description = ''
        Host path to an env file (KEY=VALUE lines, sops-templated) bind-
        mounted as the litellm systemd service's EnvironmentFile. Must
        contain masterKeyEnvVar's value and every backend's apiKeyEnvVar
        value that isn't null — the generated config.yaml references
        them via LiteLLM's `os.environ/VARNAME` syntax, never inline.
      '';
      default = null;
    };
    masterKeyEnvVar = lib.mkOption {
      type = lib.types.str;
      default = "LITELLM_MASTER_KEY";
      description = ''
        Env var (from secretsFile) holding the REAL LiteLLM master/admin
        key — this is the credential that can mint virtual keys, Teams,
        and budgets, so it must be a real secret, not the hardcoded
        "sk-1234" placeholder this option replaces. Generate one
        yourself (e.g. `openssl rand -hex 32`) and sops-set it.
      '';
    };
    backends = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption { type = lib.types.str; };
            model = lib.mkOption {
              type = lib.types.str;
              description = "litellm-style model id, e.g. \"ollama/qwen2.5-coder:32b\" (self-hosted) or \"anthropic/claude-opus-4-7\" (cloud provider).";
            };
            url = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "api_base — set for self-hosted backends (Ollama etc.) that need a URL. Leave null for cloud providers (Anthropic, OpenAI) LiteLLM already knows the endpoint for.";
            };
            apiKeyEnvVar = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Env var (from secretsFile) holding this backend's real API
                key. null means no auth needed (e.g. an unauthenticated
                local Ollama server) — this used to silently default every
                backend to a hardcoded "sk-placeholder" string regardless
                of whether real auth was needed; that's gone now, be
                explicit per backend instead.
              '';
            };
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

      # 2. Config Generation — real credentials are NEVER inlined here
      # (this file lands in /etc, i.e. the Nix store, world-readable).
      # LiteLLM's `os.environ/VARNAME` syntax defers to the process
      # environment at runtime instead, sourced from the EnvironmentFile
      # above (cfg.secretsFile, sops-templated on the host).
      environment.etc."litellm/config.yaml".text = builtins.toJSON {
        model_list = map (b: {
          model_name = b.name;
          litellm_params = {
            inherit (b) model;
            api_key = if b.apiKeyEnvVar != null then "os.environ/${b.apiKeyEnvVar}" else "sk-not-needed";
          }
          // lib.optionalAttrs (b.url != null) { api_base = b.url; };
        }) cfg.backends;
        router_settings = {
          routing_strategy = "latency-based-routing";
          enable_pre_call_checks = true;
        };
        general_settings = {
          master_key = "os.environ/${cfg.masterKeyEnvVar}";
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
