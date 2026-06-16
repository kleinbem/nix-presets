{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.nextcloud;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.nextcloud = {
    enable = lib.mkEnableOption "Nextcloud collaboration container (Phase 5 — persona files, calendar, contacts, talk)";
    ip = lib.mkOption {
      type = lib.types.str;
      description = "Container IP on the cbr0 bridge.";
    };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      description = "Host directory bind-mounted to /var/lib/nextcloud. Holds Postgres + filestore + Redis state.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "1500M";
      description = "Nextcloud + Postgres + Redis. 1.5 G comfortable for ~50 active users.";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "cloud.kleinbem.dev";
      description = "Public hostname; Caddy reverse-proxies to ip:80.";
    };
    dbPasswordFile = lib.mkOption {
      type = lib.types.str;
      description = "Path (inside container) to a file containing the Postgres password.";
    };
    adminPasswordFile = lib.mkOption {
      type = lib.types.str;
      description = "Path (inside container) to a file containing the initial admin password.";
    };
    enabledApps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "calendar"
        "contacts"
        "tasks"
        "notes"
        "deck"
        "spreed" # Nextcloud Talk
      ];
      description = ''
        Nextcloud apps to enable beyond the core. Default is the
        "collaboration baseline" set: calendar/contacts/tasks/notes/
        deck for project boards, spreed for video calls. Add
        groupfolders if you want per-persona shared folders.
      '';
    };
    oidcUpstream = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        OIDC issuer URL (Authentik). When set, the user_oidc app uses
        it as the SSO provider; personas log in via Authentik. Without
        this, fall back to local Nextcloud accounts.
      '';
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "nextcloud";
    inherit cfg;
    innerConfig = {
      services.nextcloud = {
        enable = true;
        package = pkgs.nextcloud31; # bump as needed; check release notes for breaking changes
        hostName = cfg.domain;
        https = false; # Caddy terminates TLS upstream
        configureRedis = true;
        database.createLocally = true;
        config = {
          adminuser = "admin";
          adminpassFile = cfg.adminPasswordFile;
          dbtype = "pgsql";
          dbpassFile = cfg.dbPasswordFile;
        };
        settings = {
          trusted_proxies = [ "10.85.46.0/24" ]; # the container bridge
          overwriteprotocol = "https";
        };
        extraApps = lib.genAttrs cfg.enabledApps (name: pkgs.nextcloud31Packages.apps.${name} or null);
        extraAppsEnable = true;
      };

      networking.firewall.allowedTCPPorts = [
        80
        443
      ];
    };

    bindMounts = {
      "/var/lib/nextcloud" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    };
  });
}
