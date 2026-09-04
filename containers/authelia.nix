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
    # The seed users.yml (real, argon2id-hashed accounts) -- sops-backed like
    # the three secrets above, not baked into this shared preset. A preset
    # must not embed a host-specific credential (see this repo's AGENTS.md).
    usersFile = lib.mkOption {
      type = lib.types.str;
      default = config.sops.secrets.authelia_users_file.path;
      defaultText = lib.literalExpression "config.sops.secrets.authelia_users_file.path";
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
          # "auto" follows the browser's prefers-color-scheme; Authelia
          # supports this natively so there's no need to hardcode "dark".
          theme = "auto";
          # default_redirection_url moved to session.cookies[].default_redirection_url
          # below — the global form can't coexist with `cookies` (validation error).
          # It also used to be "https://${cfg.ip}.local" here, i.e.
          # https://10.85.48.123.local — never a valid hostname.
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
                # Internal .local vhost names and the mesh-only *.kleinbem.dev
                # services that opt into caddy forward_auth (inventory node
                # auth = true). Services that must stay open (cache, ntfy, s3)
                # carry auth = false, so caddy never forwards them here.
                domain = [
                  "*.local"
                  "*.kleinbem.dev"
                ];
                policy = "one_factor";
              }
            ];
          };
          session = {
            name = "authelia_session";
            expiration = "1h";
            inactivity = "30m";
            remember_me = "1w";
            # Global `domain` can't coexist with `cookies`, and a bare "local"
            # domain is rejected outright (must have a period or be an IP) —
            # that's what was crash-looping the service. Scoped to
            # kleinbem.dev: every currently auth-gated app (code, frigate,
            # n8n) is reached via *.kleinbem.dev over the mesh/tunnel, never
            # by its .local name (mDNS/Avahi, bridge-local only) — so this
            # isn't a narrower fix than what was actually working, just a
            # valid one. authelia_url and default_redirection_url must each
            # share a cookie scope with `domain` (i.e. actually be
            # *.kleinbem.dev, not a bare IP) and must differ from each other —
            # authelia.kleinbem.dev is Authelia's own real vhost (nix-config
            # inventory.nix, mesh-only); redirect after login to the
            # dashboard rather than back to Authelia itself.
            cookies = [
              {
                domain = "kleinbem.dev";
                authelia_url = "https://authelia.kleinbem.dev/";
                default_redirection_url = "https://home.kleinbem.dev/";
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

      # Recursive ownership fix (Z) -- db.sqlite3's parent dir wasn't
      # writable by authelia-main, causing a fatal "unable to open database
      # file" startup check failure. Z re-applies every boot and, since this
      # runs inside the container on the bind-mounted path, fixes the
      # host-side directory too — same pattern as crowdsec's hostDataDir fix.
      # users.yml itself is no longer created here -- it's a sops secret,
      # copied into place by the activation script below (same reasoning as
      # jwt/session/storage secrets: a plain bind-mount can't fix the
      # decrypted file's ownership for authelia-main to read it).
      systemd.tmpfiles.rules = [
        "Z /var/lib/authelia - authelia-main authelia-main - -"
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
        # Seed users.yml from its sops secret -- `f`-type tmpfiles create-if-
        # missing doesn't apply here since this is a real secret value, not
        # a static default; copy runs every activation but is idempotent
        # (same content in, same content out) and cheap.
        if [ -f /run/secrets/authelia_users_file_host ]; then
          cp -f /run/secrets/authelia_users_file_host /var/lib/authelia/users.yml
          chown authelia-main:authelia-main /var/lib/authelia/users.yml
          chmod 600 /var/lib/authelia/users.yml
        fi
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
      "/run/secrets/authelia_users_file_host" = {
        hostPath = cfg.usersFile;
        isReadOnly = true;
      };
    };
  });
}
