# Garage UI (Noooste/garage-ui): web dashboard for the Garage S3 cluster —
# buckets, objects, keys, layout. Garage itself runs host-native (not in a
# container); this UI reaches its S3 and admin APIs on the host's bridge
# address, which the host firewall opens to this container only.
#
# View-only by default, in two layers:
# - The UI: Authentik users in oidc.viewerGroup may look and download, nothing
#   else (access_control). Token login is off, since garage-ui always makes it
#   full admin; the `garage` CLI on the host is the break-glass.
# - Garage: give it a scoped admin token (`just garage::ui-token` in
#   nix-config) and Garage itself refuses bucket, key and layout changes. The
#   scope must include GetKeyInfo, because garage-ui browses objects with the
#   S3 keys already granted on each bucket. So objects stay protected by the
#   UI layer only.
#
# Never runs without auth: with no method configured the server falls back to
# "none" (anyone reaching the port gets full admin), hence the assertion below.
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
      token.enabled = cfg.tokenLogin;
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
        role_attribute_path = "groups";
        team_attribute_path = "groups";
        cookie_secure = true;
      }
      // lib.optionalAttrs (cfg.oidc.adminGroup != null) { admin_role = cfg.oidc.adminGroup; };
    };
    logging.format = "json";
  }
  // lib.optionalAttrs cfg.oidc.enable {
    # Default-deny for OIDC users: only the viewer team gets anything.
    access_control = {
      teams = [
        {
          name = "viewers";
          claim_values = [ cfg.oidc.viewerGroup ];
          bindings = [
            {
              bucket_prefixes = [ "*" ];
              permissions = [
                "bucket.list"
                "bucket.read"
                "object.list"
                "object.read"
              ];
            }
          ];
          cluster_permissions = [
            "key.list"
            "key.read"
            "cluster.status"
            "cluster.health"
            "cluster.statistics"
            "node.info"
            "node.statistics"
          ];
        }
      ];
    };
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

          GARAGE_UI_GARAGE_ADMIN_TOKEN=<Garage admin token, ideally read-only scoped>
          GARAGE_UI_AUTH_OIDC_CLIENT_SECRET=<Authentik client secret>  (with oidc.enable)
      '';
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "256M";
    };
    tokenLogin = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Allow logging in with the Garage admin token. garage-ui always makes that login full admin.";
    };
  }
  // lib.recursiveUpdate oidcOpts {
    oidc = {
      viewerGroup = lib.mkOption {
        type = lib.types.str;
        default = "staff";
        description = "Authentik group whose members may view buckets, objects, keys and the cluster.";
      };
      adminGroup = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Authentik group whose members get full admin rights in the UI. Null: nobody.";
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = cfg.oidc.enable || cfg.tokenLogin;
            message = "my.containers.garage-ui needs oidc.enable or tokenLogin: without a login method garage-ui serves everything unauthenticated.";
          }
        ];
      }
      (mkContainer {
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
      })
    ]
  );
}
