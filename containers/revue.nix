{
  self,
  inputs ? { },
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.revue;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };

  revuePkg =
    if inputs ? revue && inputs.revue ? packages then
      inputs.revue.packages.${pkgs.system}.default
    else
      pkgs.revue or (pkgs.writeShellScriptBin "revue" "echo 'revue package not provided' && exit 1");

  hasSecrets = cfg.secretsFile != null;
  secretsPath = "/run/secrets/revue.env";
in
{
  imports = [ ../nixosModules/backup-engine ];

  options.my.containers.revue = {
    enable = lib.mkEnableOption "Revue AI Code Review daemon container";
    ip = lib.mkOption {
      type = lib.types.str;
      description = "Container IP on the cbr0 bridge.";
    };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/images/revue";
      description = "Host directory holding persistent state (SQLite database, cache).";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8383;
      description = "Port the revue daemon listens on.";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "revue.kleinbem.dev";
      description = "Public domain (terminated by Caddy reverse proxy).";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "1G";
      description = "Systemd memory ceiling for the container.";
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host path to sops-backed environment file (e.g. REVUE_WEBHOOK_SECRET=..., DATABASE_URL=...).";
    };
    meshLlmUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://10.0.0.12:9337/v1";
      description = "OpenAI-compatible REST API endpoint for fleet GPU inference.";
    };
    databaseUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Database URL (sqlite:///var/lib/revue/revue.db?mode=rwc or postgres://...). If null, defaults to embedded SQLite unless supplied in secretsFile.";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkContainer {
        inherit config;
        name = "revue";
        inherit cfg;
        inherit (cfg) secretsFile;
        secretsFilePath = secretsPath;
        subDirs = [ "data" ];
        bindMounts = {
          "/var/lib/revue" = {
            hostPath = "${cfg.hostDataDir}/data";
            isReadOnly = false;
          };
        };
        innerConfig = {
          systemd.services.revue = {
            description = "Revue AI Code Review Daemon";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" ];
            environment = {
              MESH_LLM_URL = cfg.meshLlmUrl;
              REVUE_MESH_LLM_URL = cfg.meshLlmUrl;
            }
            // lib.optionalAttrs (cfg.databaseUrl != null) {
              DATABASE_URL = cfg.databaseUrl;
            }
            // lib.optionalAttrs (cfg.databaseUrl == null && !hasSecrets) {
              DATABASE_URL = "sqlite:///var/lib/revue/revue.db?mode=rwc";
            };
            serviceConfig = {
              Type = "simple";
              ExecStart = "${revuePkg}/bin/revue daemon --listen 0.0.0.0:${toString cfg.port}";
              Restart = "always";
              RestartSec = "5s";
              StateDirectory = "revue";
              WorkingDirectory = "/var/lib/revue";
              EnvironmentFile = lib.optional hasSecrets secretsPath;
            };
          };

          networking.firewall.allowedTCPPorts = [ cfg.port ];
        };
      })

      # Register backup engine
      {
        my.backup.items.revue = {
          tier = "secure";
          sqlite = [ "${cfg.hostDataDir}/data/revue.db" ];
          paths = [ "${cfg.hostDataDir}/data" ];
          exclude = [ "${cfg.hostDataDir}/data/revue.db*" ];
        };
      }
    ]
  );
}
