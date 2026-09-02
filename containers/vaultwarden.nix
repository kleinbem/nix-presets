{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.vaultwarden;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };

  hasAdminToken = cfg.adminTokenFile != null;
  hasSmtp = cfg.smtp != null;

  # Fixed paths the secret files are bind-mounted to *inside* the container
  # (the host attrs hold sops-nix paths, resolved on the deploying host).
  adminTokenPath = "/run/secrets/vaultwarden-admin-token";
  smtpPasswordPath = "/run/secrets/vaultwarden-smtp-password";
in
{
  options.my.containers.vaultwarden = {
    enable = lib.mkEnableOption "Vaultwarden Container (self-hosted Bitwarden-compatible vault)";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      description = "Host dir bind-mounted to /var/lib/vaultwarden — holds db.sqlite3, attachments, RSA keys.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "512M";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "vault.kleinbem.dev";
      description = ''
        Public host (no scheme). Passed to services.vaultwarden.domain, which
        derives DOMAIN=https://<domain> — required for WebAuthn, attachments and
        invite links. Caddy + the Cloudflare tunnel terminate TLS in front.
      '';
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8222;
      description = "Rocket HTTP port inside the container (Caddy reverse-proxies to it).";
    };
    signupsAllowed = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "SIGNUPS_ALLOWED — open self-registration. Fleet default is invite-only.";
    };
    invitationsAllowed = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "INVITATIONS_ALLOWED — let admins/orgs invite users even with signups closed.";
    };

    # Secret file paths (host-level bind mounts, resolved via sops on the
    # deploying host — never part of the container closure, so the
    # container-factory passes dummies).
    adminTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        File containing an Argon2 PHC hash for ADMIN_TOKEN
        (`vaultwarden hash --preset owasp`). null ⇒ /admin disabled, service
        still starts. Required for the persona provisioning workflow.
      '';
    };

    smtp = lib.mkOption {
      default = null;
      description = ''
        Outbound SMTP for invite / verification mail. null ⇒ no mail; invite
        links must be read from /admin or the server log. Wire this once the
        Stalwart persona mail server is live.
      '';
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            host = lib.mkOption { type = lib.types.str; };
            port = lib.mkOption {
              type = lib.types.port;
              default = 587;
            };
            security = lib.mkOption {
              type = lib.types.enum [
                "starttls"
                "force_tls"
                "off"
              ];
              default = "starttls";
            };
            from = lib.mkOption { type = lib.types.str; };
            fromName = lib.mkOption {
              type = lib.types.str;
              default = "Vaultwarden";
            };
            username = lib.mkOption { type = lib.types.str; };
            passwordFile = lib.mkOption { type = lib.types.str; };
          };
        }
      );
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "vaultwarden";
    cfg = cfg // {
      privateUsers = "no";
      # Host dir is created root:root; the inner tmpfiles `Z` rule below
      # recursively chowns it to the container's vaultwarden user before the
      # service starts (same pattern as crowdsec.nix).
      dataDirOwner = "root";
      dataDirGroup = "root";
    };
    innerConfig = {
      services.vaultwarden = {
        enable = true;
        dbBackend = "sqlite";
        inherit (cfg) domain;
        environmentFile = "/run/vaultwarden.env";
        config = {
          ROCKET_ADDRESS = "0.0.0.0";
          ROCKET_PORT = cfg.port;
          ROCKET_WORKERS = 4;
          SIGNUPS_ALLOWED = cfg.signupsAllowed;
          SIGNUPS_VERIFY = false; # needs SMTP; flip on once mail is wired
          INVITATIONS_ALLOWED = cfg.invitationsAllowed;
          WEB_VAULT_ENABLED = true;
        }
        // lib.optionalAttrs hasSmtp {
          SMTP_HOST = cfg.smtp.host;
          SMTP_PORT = cfg.smtp.port;
          SMTP_SECURITY = cfg.smtp.security;
          SMTP_FROM = cfg.smtp.from;
          SMTP_FROM_NAME = cfg.smtp.fromName;
          SMTP_USERNAME = cfg.smtp.username;
        };
      };

      systemd = {
        services = {
          # Compose the runtime env file (secrets) from the bind-mounted sops
          # files — kept out of the world-readable Nix store.
          vaultwarden-env-setup = {
            description = "Materialise vaultwarden secret environment from sops files";
            wantedBy = [ "vaultwarden.service" ];
            before = [ "vaultwarden.service" ];
            serviceConfig.Type = "oneshot";
            script = ''
              umask 077
              {
                : # keep the group non-empty when no secrets are configured
                ${lib.optionalString hasAdminToken "printf 'ADMIN_TOKEN=%s\\n' \"$(cat ${adminTokenPath})\""}
                ${lib.optionalString hasSmtp "printf 'SMTP_PASSWORD=%s\\n' \"$(cat ${smtpPasswordPath})\""}
              } > /run/vaultwarden.env
            '';
          };

          vaultwarden = {
            after = [ "vaultwarden-env-setup.service" ];
            wants = [ "vaultwarden-env-setup.service" ];
          };
        };

        # Recursively hand the bind-mounted state dir to the vaultwarden user
        # (the host creates it root:root).
        tmpfiles.rules = [ "Z /var/lib/vaultwarden - vaultwarden vaultwarden - -" ];
      };

      networking.firewall.allowedTCPPorts = [ cfg.port ];
    };

    bindMounts = {
      "/var/lib/vaultwarden" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    }
    // lib.optionalAttrs hasAdminToken {
      ${adminTokenPath} = {
        hostPath = cfg.adminTokenFile;
        isReadOnly = true;
      };
    }
    // lib.optionalAttrs hasSmtp {
      ${smtpPasswordPath} = {
        hostPath = cfg.smtp.passwordFile;
        isReadOnly = true;
      };
    };
  });
}
