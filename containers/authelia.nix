{ self }:
{
  config,
  lib,
  myInventory,
  ...
}:
let
  cfg = config.my.containers.authelia;
  inherit (self.lib) mkContainer;
  inv = myInventory;
in
{
  options.my.containers.authelia = {
    enable = lib.mkEnableOption "Authelia SSO Container";
    ip = lib.mkOption {
      type = lib.types.str;
      default = inv.network.nodes.authelia.ip or "10.85.46.123";
    };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "local";
    };
    # Host paths bind-mounted into the container. Defaults resolve via sops-nix,
    # so hosts without the sops module (container-factory) must override them —
    # they are host-level bind mounts and never part of the container closure.
    jwtSecretFile = lib.mkOption {
      type = lib.types.str;
      default = config.sops.secrets.authelia_jwt_secret.path;
      defaultText = lib.literalExpression "config.sops.secrets.authelia_jwt_secret.path";
    };
    sessionSecretFile = lib.mkOption {
      type = lib.types.str;
      default = config.sops.secrets.authelia_session_secret.path;
      defaultText = lib.literalExpression "config.sops.secrets.authelia_session_secret.path";
    };
    storageEncryptionKeyFile = lib.mkOption {
      type = lib.types.str;
      default = config.sops.secrets.authelia_storage_encryption_key.path;
      defaultText = lib.literalExpression "config.sops.secrets.authelia_storage_encryption_key.path";
    };
  };

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "authelia";
    inherit cfg;
    innerConfig = {
      services.authelia.instances.main = {
        enable = true;
        settings = {
          theme = "dark";
          default_redirection_url = "https://${cfg.ip}.local";
          server = {
            address = "tcp://0.0.0.0:9091";
          };
          log = {
            level = "debug";
            format = "text";
          };
          totp = {
            issuer = "NixOS-Fleet";
          };
          authentication_backend = {
            file = {
              path = "/var/lib/authelia/users.yml";
            };
          };
          access_control = {
            default_policy = "deny";
            rules = [
              {
                domain = "*.local";
                policy = "one_factor";
              }
            ];
          };
          session = {
            name = "authelia_session";
            inherit (cfg) domain;
            expiration = "1h";
            inactivity = "30m";
            remember_me_duration = "1w";
            cookies = [
              {
                inherit (cfg) domain;
                authelia_url = "https://authelia.local";
              }
            ];
          };
          storage = {
            local = {
              path = "/var/lib/authelia/db.sqlite3";
            };
          };
          notifier = {
            disable_startup_check = true;
            filesystem = {
              filename = "/var/lib/authelia/notification.txt";
            };
          };
        };
        # Use secrets from sops
        secrets = {
          jwtSecretFile = "/run/secrets/authelia_jwt_secret";
          sessionSecretFile = "/run/secrets/authelia_session_secret";
          storageEncryptionKeyFile = "/run/secrets/authelia_storage_encryption_key";
        };
      };

      networking.firewall.allowedTCPPorts = [ 9091 ];

      # Create a dummy users.yml if it doesn't exist (User should manage this)
      systemd.tmpfiles.rules = [
        "f /var/lib/authelia/users.yml 0600 root root - users: {}"
      ];

      # Ensure the secret files are reachable inside the container with proper permissions
      system.activationScripts.authelia-secrets.text = ''
        mkdir -p /run/secrets
        for secret in jwt_secret session_secret storage_encryption_key; do
          if [ -f /run/secrets/authelia_''${secret}_host ]; then
            cp -f /run/secrets/authelia_''${secret}_host /run/secrets/authelia_''${secret}
            chown authelia-main:authelia-main /run/secrets/authelia_''${secret}
            chmod 400 /run/secrets/authelia_''${secret}
          fi
        done
      '';
    };
    bindMounts = {
      "/var/lib/authelia" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
      "/run/secrets/authelia_jwt_secret_host" = {
        hostPath = cfg.jwtSecretFile;
        isReadOnly = true;
      };
      "/run/secrets/authelia_session_secret_host" = {
        hostPath = cfg.sessionSecretFile;
        isReadOnly = true;
      };
      "/run/secrets/authelia_storage_encryption_key_host" = {
        hostPath = cfg.storageEncryptionKeyFile;
        isReadOnly = true;
      };
    };
  });
}
