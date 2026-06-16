{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.odoo;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.odoo = {
    enable = lib.mkEnableOption "Odoo Community ERP/HRIS container (Phase 4 — persona directory, leave, org chart)";
    ip = lib.mkOption {
      type = lib.types.str;
      description = "Container IP on the cbr0 bridge.";
    };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      description = "Host directory bind-mounted to /var/lib/odoo. Holds Postgres data + filestore.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "3G";
      description = "Odoo workers + Postgres. 3G comfortable for ~30 personas; raise for more.";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = "hr.kleinbem.dev";
      description = "Public hostname; Caddy reverse-proxies to ip:8069.";
    };
    addons = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "hr"
        "hr_holidays"
        "hr_skills"
        "calendar"
      ];
      description = ''
        Odoo modules to keep enabled. The default set is HR-only;
        explicitly avoid CRM/Sales/Accounting unless you want the
        full ERP. To run leaner: drop calendar (pull from Nextcloud
        via CalDAV instead).
      '';
    };
    dbPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path (inside container) to a file containing the Postgres password.";
    };
    adminPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path (inside container) to a file containing the Odoo master/admin password.";
    };
    oidcUpstream = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        OIDC issuer URL (Authentik). When set, Odoo uses it as the
        authentication provider; users sync from Authentik. Without
        this, fall back to local Odoo accounts.
      '';
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "odoo";
    inherit cfg;
    innerConfig = {
      services.odoo = {
        enable = true;
        addons = map (a: pkgs.odoo-addons.${a} or null) cfg.addons;
        settings = {
          options = {
            admin_passwd = "@@ADMIN_PWD@@"; # replaced by env-setup unit
            db_host = "localhost";
            db_user = "odoo";
            db_password = "@@DB_PWD@@";
            xmlrpc_port = 8069;
            longpolling_port = 8072;
            workers = 2;
            limit_memory_soft = 671088640; # 640 MB per worker
            limit_memory_hard = 805306368; # 768 MB per worker
            proxy_mode = true; # behind Caddy
          };
        };
      };

      systemd.services.odoo-env-setup = {
        description = "Substitute Odoo runtime secrets from sops-templated files";
        wantedBy = [ "odoo.service" ];
        before = [ "odoo.service" ];
        serviceConfig.Type = "oneshot";
        script = ''
          ${lib.optionalString (cfg.dbPasswordFile != null && cfg.adminPasswordFile != null) ''
            DB_PWD=$(cat ${cfg.dbPasswordFile})
            ADMIN_PWD=$(cat ${cfg.adminPasswordFile})
            sed -i "s|@@DB_PWD@@|$DB_PWD|; s|@@ADMIN_PWD@@|$ADMIN_PWD|" /etc/odoo/odoo.conf
          ''}
        '';
      };

      networking.firewall.allowedTCPPorts = [
        8069 # web UI
        8072 # long-polling
      ];
    };

    bindMounts = {
      "/var/lib/odoo" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    };
  });
}
