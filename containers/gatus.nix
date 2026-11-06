{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.gatus;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };

  hasEndpointsFile = cfg.endpointsFile != null;

  # gatus merges every YAML file in a config directory (arrays appended), so
  # the built-in base config and the host's bind-mounted endpoints sit side by side.
  configDir = "/run/gatus/conf.d";
  endpointsPath = "${configDir}/10-endpoints.yaml";

  baseConfig = (pkgs.formats.yaml { }).generate "gatus-base.yaml" {
    web.port = cfg.port;
    ui.title = "kleinbem Status";
  };

  ntfy = cfg.alerting.ntfy;
  hasNtfy = ntfy.topicFile != null;
  ntfyTopicPath = "/run/secrets/gatus-ntfy-topic";
  ntfyTokenPath = "/run/secrets/gatus-ntfy-token";
  envFile = "/run/gatus/alerting.env";

  fallback = cfg.alerting.fallback;
  hasFallback = fallback.topicFile != null;
  hasEnv = hasNtfy || hasFallback;
  fallbackTopicPath = "/run/secrets/gatus-fallback-topic";

  # A second route that skips our own ntfy server and the tunnel in front of it.
  # The custom provider substitutes placeholders in url and body only, not headers.
  fallbackConfig = (pkgs.formats.yaml { }).generate "gatus-fallback.yaml" {
    alerting.custom = {
      url = "${fallback.url}/\${GATUS_FALLBACK_TOPIC}";
      method = "POST";
      headers = {
        Title = "Gatus (fallback)";
        Priority = toString fallback.priority;
      };
      body = "[ALERT_TRIGGERED_OR_RESOLVED]: [ENDPOINT_NAME] [ALERT_DESCRIPTION]";
      default-alert = {
        failure-threshold = 2;
        success-threshold = 2;
        send-on-resolved = true;
      };
    };
  };

  # Topic and token stay out of the store: gatus expands ''${VAR} from its
  # environment, which gatus-config-setup fills from the bind-mounted files.
  # Two variants because the token is optional per host, decided at runtime.
  alertingConfig =
    withToken:
    (pkgs.formats.yaml { }).generate "gatus-alerting.yaml" {
      alerting.ntfy = {
        inherit (ntfy) url priority;
        topic = "\${GATUS_NTFY_TOPIC}";
        default-alert = {
          failure-threshold = 2;
          success-threshold = 2;
          send-on-resolved = true;
        };
      }
      // lib.optionalAttrs withToken { token = "\${GATUS_NTFY_TOKEN}"; };
    };
in
{
  options.my.containers.gatus = {
    enable = lib.mkEnableOption "Gatus status page / uptime monitor container";
    ip = lib.mkOption { type = lib.types.str; };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Gatus web UI port inside the container (Caddy reverse-proxies to it).";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "128M";
    };
    # A bind mount, not baked in: container-factory builds the container once
    # for all hosts (ADR-002), so the host-specific list must come from the host.
    endpointsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path (on the deploying host) to a YAML file containing an
        `endpoints:` list (see https://gatus.io/docs#endpoints), bind-
        mounted read-only into the container and merged with the portable
        base config. null ⇒ gatus starts with zero endpoints, which gatus
        itself refuses to run with — set this on the deploying host, not
        here (this preset stays portable).
      '';
    };
    # Endpoints alert only when they list `alerts = [ { type = "ntfy"; } ]`.
    alerting.ntfy = {
      url = lib.mkOption {
        type = lib.types.str;
        default = "https://ntfy.sh";
        description = "ntfy server gatus posts alerts to. Baked into the closure, so set it where the container is built.";
      };
      topicFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Host path to a file with the ntfy topic (e.g. a sops secret's .path), bind-mounted in. null disables alerting.";
      };
      tokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Host path to a file with an ntfy access token, for servers that require auth. Optional.";
      };
      priority = lib.mkOption {
        type = lib.types.ints.between 1 5;
        default = 4;
        description = "ntfy priority of the alerts. Baked into the closure.";
      };
    };
    # Endpoints use it with `alerts = [ { type = "custom"; } ]`.
    alerting.fallback = {
      url = lib.mkOption {
        type = lib.types.str;
        default = "https://ntfy.sh";
        description = "Public ntfy server for the fallback route. Baked into the closure.";
      };
      topicFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Host path to a file with the fallback topic: 1-64 of [-_A-Za-z0-9], long and random, since public ntfy topics are open to anyone who knows the name. null disables the route.";
      };
      priority = lib.mkOption {
        type = lib.types.ints.between 1 5;
        default = 5;
        description = "ntfy priority of fallback alerts. Baked into the closure.";
      };
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "gatus";
    inherit cfg;
    innerConfig = {
      services.gatus = {
        enable = true;
        configFile = configDir;
        environmentFile = lib.mkIf hasEnv envFile;
      };

      # Link the base config next to the bind-mounted endpoints file (in /run,
      # not /etc, to avoid racing etc activation).
      systemd.services = {
        gatus-config-setup = {
          description = "Materialise gatus base config for GATUS_CONFIG_PATH merge";
          wantedBy = [ "gatus.service" ];
          before = [ "gatus.service" ];
          serviceConfig.Type = "oneshot";
          script = ''
            mkdir -p ${configDir}
            ln -sf ${baseConfig} ${configDir}/00-base.yaml
          ''
          + lib.optionalString hasEnv ''
            umask 077
            : > ${envFile}
          ''
          + lib.optionalString hasNtfy ''
            printf 'GATUS_NTFY_TOPIC=%s\n' "$(cat ${ntfyTopicPath})" >> ${envFile}
            if [ -r ${ntfyTokenPath} ]; then
              printf 'GATUS_NTFY_TOKEN=%s\n' "$(cat ${ntfyTokenPath})" >> ${envFile}
              ln -sf ${alertingConfig true} ${configDir}/05-alerting.yaml
            else
              ln -sf ${alertingConfig false} ${configDir}/05-alerting.yaml
            fi
          ''
          + lib.optionalString hasFallback ''
            # The topic goes into the URL; a bad one only drops the fallback, not Gatus.
            fallbackTopic=$(cat ${fallbackTopicPath})
            rm -f ${configDir}/06-fallback.yaml
            if [[ "$fallbackTopic" =~ ^[-_A-Za-z0-9]{1,64}$ ]]; then
              printf 'GATUS_FALLBACK_TOPIC=%s\n' "$fallbackTopic" >> ${envFile}
              ln -sf ${fallbackConfig} ${configDir}/06-fallback.yaml
            else
              echo "gatus fallback topic must match [-_A-Za-z0-9]{1,64}; fallback alerts disabled" >&2
            fi
          '';
        };
        gatus = {
          after = [ "gatus-config-setup.service" ];
          wants = [ "gatus-config-setup.service" ];
        };
      };

      # In-memory storage only: a restart resets uptime history, which is fine here.
      networking.firewall.allowedTCPPorts = [ cfg.port ];
    };

    bindMounts =
      lib.optionalAttrs hasEndpointsFile {
        ${endpointsPath} = {
          hostPath = "${cfg.endpointsFile}";
          isReadOnly = true;
        };
      }
      // lib.optionalAttrs hasNtfy {
        ${ntfyTopicPath} = {
          hostPath = ntfy.topicFile;
          isReadOnly = true;
        };
      }
      // lib.optionalAttrs (hasNtfy && ntfy.tokenFile != null) {
        ${ntfyTokenPath} = {
          hostPath = ntfy.tokenFile;
          isReadOnly = true;
        };
      }
      // lib.optionalAttrs hasFallback {
        ${fallbackTopicPath} = {
          hostPath = fallback.topicFile;
          isReadOnly = true;
        };
      };
  });
}
