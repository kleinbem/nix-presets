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
    inputs.coderabbit-steward.packages.${pkgs.stdenv.hostPlatform.system}.default
      or pkgs.coderabbit-steward;

  hasSecrets = cfg.secretsFile != null;
  secretsPath = "/run/secrets/coderabbit-steward.env";
  hasPrivateKey = cfg.privateKeyFile != null;
  privateKeyPath = "/run/secrets/coderabbit-steward.pem";
  inboundTls = cfg.tls.enable && cfg.tls.serverPort > 0;
  listenHost = if inboundTls then "127.0.0.1" else "0.0.0.0";
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
      description = "Host path to sops-backed environment file (GITHUB_APP_ID, CR_STEWARD_API_TOKEN).";
    };
    privateKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host path to sops-backed GitHub App private key PEM file.";
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
        }
        // lib.optionalAttrs hasPrivateKey {
          ${privateKeyPath} = {
            hostPath = cfg.privateKeyFile;
            isReadOnly = true;
          };
        };
        innerConfig = {
          users.users.coderabbit-steward = {
            isSystemUser = true;
            group = "coderabbit-steward";
          };
          users.groups.coderabbit-steward = { };

          systemd.services.coderabbit-steward = {
            description = "coderabbit-steward CodeRabbit OSS Daemon";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" ];
            environment = {
              DATABASE_URL = "sqlite:///var/lib/coderabbit-steward/steward.db?mode=rwc";
              CR_STEWARD_MODE = cfg.mode;
            }
            // lib.optionalAttrs hasPrivateKey {
              GITHUB_APP_PRIVATE_KEY_FILE = privateKeyPath;
            };
            serviceConfig = {
              Type = "simple";
              User = "coderabbit-steward";
              Group = "coderabbit-steward";
              ExecStart = "${stewardPkg}/bin/cr-steward daemon --listen ${listenHost}:${toString cfg.port}";
              Restart = "always";
              RestartSec = "5s";
              StateDirectory = "coderabbit-steward";
              WorkingDirectory = "/var/lib/coderabbit-steward";
              EnvironmentFile = lib.optional hasSecrets secretsPath;
              NoNewPrivileges = true;
              PrivateTmp = true;
            };
          };

          networking.firewall.allowedTCPPorts = lib.optional (!inboundTls) cfg.port;
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
