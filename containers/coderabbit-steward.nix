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
  cfg = config.my.containers.coderabbit-steward;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };

  stewardPkg =
    if inputs ? coderabbit-steward && inputs.coderabbit-steward ? packages then
      inputs.coderabbit-steward.packages.${pkgs.system}.default
    else
      pkgs.coderabbit-steward
        or (pkgs.writeShellScriptBin "cr-steward" "echo 'coderabbit-steward package not provided' && exit 1");

  hasSecrets = cfg.secretsFile != null;
  secretsPath = "/run/secrets/coderabbit-steward.env";
in
{
  imports = [ ../nixosModules/backup-engine ];

  options.my.containers.coderabbit-steward = {
    enable = lib.mkEnableOption "coderabbit-steward CodeRabbit OSS budget and review steward container";
    ip = lib.mkOption {
      type = lib.types.str;
      description = "Container IP on the cbr0 bridge.";
    };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/images/coderabbit-steward";
      description = "Host directory holding persistent state (SQLite database).";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8484;
      description = "Port the cr-steward daemon listens on.";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "steward.kleinbem.dev";
      description = "Public domain (terminated by Caddy reverse proxy).";
    };
    mode = lib.mkOption {
      type = lib.types.enum [
        "observe"
        "on-demand"
        "full"
      ];
      default = "observe";
      description = "Operating mode for the steward.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "128M";
      description = "Systemd memory ceiling for the container.";
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host path to sops-backed environment file (GITHUB_APP_ID, GITHUB_APP_PRIVATE_KEY, CR_STEWARD_API_TOKEN).";
    };
    databaseUrl = lib.mkOption {
      type = lib.types.str;
      default = "sqlite:///var/lib/coderabbit-steward/steward.db?mode=rwc";
      description = "SQLite database URL inside the container.";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkContainer {
        inherit config;
        name = "coderabbit-steward";
        inherit cfg;
        inherit (cfg) secretsFile;
        secretsFilePath = secretsPath;
        subDirs = [ "data" ];
        bindMounts = {
          "/var/lib/coderabbit-steward" = {
            hostPath = "${cfg.hostDataDir}/data";
            isReadOnly = false;
          };
        };
        innerConfig = {
          systemd.services.coderabbit-steward = {
            description = "coderabbit-steward CodeRabbit OSS Daemon";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" ];
            environment = {
              DATABASE_URL = cfg.databaseUrl;
              CR_STEWARD_MODE = cfg.mode;
            };
            serviceConfig = {
              Type = "simple";
              ExecStart = "${stewardPkg}/bin/cr-steward daemon --listen 0.0.0.0:${toString cfg.port}";
              Restart = "always";
              RestartSec = "5s";
              StateDirectory = "coderabbit-steward";
              WorkingDirectory = "/var/lib/coderabbit-steward";
              EnvironmentFile = lib.optional hasSecrets secretsPath;
            };
          };

          networking.firewall.allowedTCPPorts = [ cfg.port ];
        };
      })

      {
        my.backup.items.coderabbit-steward = {
          tier = "secure";
          sqlite = [ "${cfg.hostDataDir}/data/steward.db" ];
          paths = [ "${cfg.hostDataDir}/data" ];
          exclude = [ "${cfg.hostDataDir}/data/steward.db*" ];
        };
      }
    ]
  );
}
