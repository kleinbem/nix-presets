{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.n8n;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.n8n = {
    enable = lib.mkEnableOption "n8n Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "4G";
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path on the host to a .env file containing N8N_ENCRYPTION_KEY and other secrets";
    };
    noteDirs = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "n8n";
    inherit cfg;
    innerConfig = {
      nixpkgs.config.allowUnfree = true;
      services.n8n = {
        enable = true;
        openFirewall = true;
        environment = {
          N8N_LISTEN_ADDRESS = "0.0.0.0";
          N8N_PORT = "5678";
          N8N_PROTOCOL = "http";
          N8N_SECURE_COOKIE = "false";
          N8N_CORS_ALLOWED_ORIGINS = "*";
          N8N_RUNNERS_AUTH_TOKEN_FILE = "/dev/null";
        };
      };
      systemd.services.n8n.serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = lib.mkForce "root";
        ReadWritePaths = [ "/var/lib/n8n" ];
        EnvironmentFile = "/run/secrets/n8n.env";
      };
    };
    bindMounts = {
      "/var/lib/n8n" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    }
    // lib.optionalAttrs (cfg.secretsFile != null) {
      "/run/secrets/n8n.env" = {
        hostPath = cfg.secretsFile;
        isReadOnly = true;
      };
    }
    // (lib.mapAttrs' (
      name: path:
      lib.nameValuePair "/mnt/ingest/${name}" {
        hostPath = path;
        isReadOnly = true;
      }
    ) cfg.noteDirs);
  });
}
