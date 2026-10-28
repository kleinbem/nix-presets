# Garage UI (Noooste/garage-ui): web dashboard for the Garage S3 cluster —
# buckets, objects, keys, layout. Garage itself runs host-native (not in a
# container); this UI reaches its S3 and admin APIs on the host's bridge
# address, which the host firewall opens to this container only.
#
# Login: Authentik OIDC when oidc.enable, plus the Garage admin token as a
# break-glass login. Never runs without auth: with no method configured the
# server falls back to "none" (anyone reaching the port gets full admin).
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.garage-ui;
  inherit (self.lib) mkContainer;
  oidcOpts = import ../lib/oidc-options.nix {
    inherit lib;
    defaultName = "garage-ui";
  };

  # The host is the bridge gateway, .1 of the container's own /24 — the same
  # address mkContainer bakes in as the default gateway. Derived rather than
  # an option, so the factory-built closure is right on whichever host runs it.
  hostAddress =
    let
      octets = lib.splitString "." (lib.head (lib.splitString "/" cfg.ip));
    in
    lib.concatStringsSep "." (lib.take 3 octets ++ [ "1" ]);

  settings = {
    server = {
      host = "0.0.0.0";
      inherit (cfg) port;
      environment = "production";
      root_url = cfg.rootUrl;
    };
    garage = {
      endpoint = "http://${hostAddress}:${toString cfg.s3Port}";
      admin_endpoint = "http://${hostAddress}:${toString cfg.adminPort}";
      inherit (cfg) region;
    };
    auth = {
      jwt_private_key_path = "/var/lib/garage-ui/jwt-key.pem";
      token.enabled = true;
    }
    // lib.optionalAttrs cfg.oidc.enable {
      oidc = {
        enabled = true;
        provider_name = "Authentik";
        client_id = cfg.oidc.clientId;
        # garage-ui wants the issuer itself, not its discovery document.
        issuer_url = lib.removeSuffix ".well-known/openid-configuration" cfg.oidc.issuerUrl;
        inherit (cfg.oidc) scopes;
        # Authentik's profile scope sends the user's group names as `groups`.
        # garage-ui refuses OIDC without an admin role, rather than making
        # every authenticated user an admin.
        role_attribute_path = "groups";
        admin_role = cfg.oidc.adminGroup;
        cookie_secure = true;
      };
    };
    logging.format = "json";
  };
  configFile = (pkgs.formats.yaml { }).generate "garage-ui.yaml" settings;
in
{
  options.my.containers.garage-ui = {
    enable = lib.mkEnableOption "Garage UI web dashboard container";
    ip = lib.mkOption {
      type = lib.types.str;
      description = "Container IP (CIDR) on the host bridge. Garage must run on that host.";
    };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/images/garage-ui";
      description = "Host directory holding the JWT signing key, so sessions survive restarts.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
    };
    rootUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://garage.kleinbem.dev";
      description = "Public URL, used for the OIDC redirect.";
    };
    region = lib.mkOption {
      type = lib.types.str;
      default = "garage";
      description = "Garage's s3_region.";
    };
    s3Port = lib.mkOption {
      type = lib.types.port;
      default = 3900;
    };
    adminPort = lib.mkOption {
      type = lib.types.port;
      default = 3903;
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Host path to an env file, bind-mounted to /run/secrets/garage-ui.env:

          GARAGE_UI_GARAGE_ADMIN_TOKEN=<garage admin token>
          GARAGE_UI_AUTH_OIDC_CLIENT_SECRET=<Authentik client secret>  (with oidc.enable)
      '';
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "256M";
    };
  }
  // lib.recursiveUpdate oidcOpts {
    oidc.adminGroup = lib.mkOption {
      type = lib.types.str;
      default = "staff";
      description = "Authentik group whose members get admin rights in the UI.";
    };
  };

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "garage-ui";
    cfg = cfg // {
      # The container's tmpfiles hands the dir to its own garage-ui user.
      dataDirOwner = "root";
      dataDirGroup = "root";
    };
    inherit (cfg) secretsFile;
    innerConfig = {
      # garage-ui comes from NixOS/nixpkgs#580190 via nix-packages until it
      # lands in nixpkgs.
      nixpkgs.overlays = [ self.inputs.nix-packages.overlays.default ];

      users.users.garage-ui = {
        isSystemUser = true;
        group = "garage-ui";
      };
      users.groups.garage-ui = { };

      systemd.tmpfiles.rules = [ "Z /var/lib/garage-ui 0700 garage-ui garage-ui - -" ];

      systemd.services.garage-ui = {
        description = "Garage UI";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${lib.getExe pkgs.garage-ui} --config ${configFile}";
          EnvironmentFile = lib.mkIf (cfg.secretsFile != null) "/run/secrets/garage-ui.env";
          User = "garage-ui";
          Group = "garage-ui";
          WorkingDirectory = "/var/lib/garage-ui";
          Restart = "on-failure";
          RestartSec = "5s";

          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ReadWritePaths = [ "/var/lib/garage-ui" ];
          CapabilityBoundingSet = [ "" ];
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
          ];
          SystemCallFilter = [ "@system-service" ];
        };
      };

      networking.firewall.allowedTCPPorts = [ cfg.port ];
    };

    bindMounts."/var/lib/garage-ui" = {
      hostPath = cfg.hostDataDir;
      isReadOnly = false;
    };
  });
}
