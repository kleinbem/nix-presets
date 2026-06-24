{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.authentik;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.authentik = {
    enable = lib.mkEnableOption "Authentik IdP Container (persona OIDC, Matrix federation, sigstore — Phase 3+)";
    ip = lib.mkOption {
      type = lib.types.str;
      description = "Container IP on the cbr0 bridge.";
    };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      description = "Host directory bind-mounted to /var/lib/authentik. Holds Postgres data + media uploads.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "1G";
      description = "Authentik + Postgres + Redis run in this container — 1G is comfortable for ~50 persona users.";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "auth.kleinbem.dev";
      description = "Public-facing hostname (Caddy reverse-proxies to ip:9000).";
    };
    secretKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path (inside container) to a file containing the AUTHENTIK_SECRET_KEY. Required at first start. Generate with: openssl rand -hex 32";
    };
    postgresPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path (inside container) to a file containing the Postgres password.";
    };
    bootstrapAdminPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path (inside container) to a file containing the initial admin (akadmin) password. Used only on first start.";
    };
    bootstrapApiTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Path (inside container) to a file containing the initial API token
        for akadmin. This is what Terraform uses to provision persona users
        from personas.nix — without it, you have to bootstrap users by hand
        through the web UI on first run.
      '';
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "authentik";
    inherit cfg;
    innerConfig = {
      services.authentik = {
        enable = true;
        environmentFile = "/run/authentik.env";

        # Embedded Postgres + Redis — fine at persona-fleet scale.
        # If/when you scale past ~500 users, externalize Postgres.
        settings = {
          email = {
            # Outbound auth notifications go through Stalwart → SES.
            host = "stalwart";
            port = 587;
            use_tls = true;
            from = "auth@kleinbem.dev";
          };
        };
      };

      # Compose the environment file from sops-templated secrets.
      systemd.services.authentik-env-setup = {
        description = "Materialise authentik environment from sops files";
        wantedBy = [ "authentik.service" ];
        before = [ "authentik.service" ];
        serviceConfig.Type = "oneshot";
        script = ''
          umask 077
          {
            ${lib.optionalString (
              cfg.secretKeyFile != null
            ) ''printf "AUTHENTIK_SECRET_KEY=%s\n" "$(cat ${cfg.secretKeyFile})"''}
            ${lib.optionalString (
              cfg.postgresPasswordFile != null
            ) ''printf "AUTHENTIK_POSTGRESQL__PASSWORD=%s\n" "$(cat ${cfg.postgresPasswordFile})"''}
            ${lib.optionalString (
              cfg.bootstrapAdminPasswordFile != null
            ) ''printf "AUTHENTIK_BOOTSTRAP_PASSWORD=%s\n" "$(cat ${cfg.bootstrapAdminPasswordFile})"''}
            ${lib.optionalString (
              cfg.bootstrapApiTokenFile != null
            ) ''printf "AUTHENTIK_BOOTSTRAP_TOKEN=%s\n" "$(cat ${cfg.bootstrapApiTokenFile})"''}
          } > /run/authentik.env
        '';
      };

      networking.firewall.allowedTCPPorts = [
        9000 # HTTP
        9443 # HTTPS (used internally; Caddy fronts publicly)
      ];
    };

    bindMounts = {
      "/var/lib/authentik" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    };
  });
}
