{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.code-server;
  commonData = import ../code-common/settings.nix;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.code-server = {
    enable = lib.mkEnableOption "Code-Server Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    user = lib.mkOption {
      type = lib.types.str;
      default = "martin";
      description = "The username to create inside the container.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "4G";
    };
    privateUsers = lib.mkOption {
      type = lib.types.str;
      default = "no";
    };
    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    allowedSources = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[0-9.]+(/[0-9]+)?");
      default = [ ];
      example = [ "10.85.48.107" ];
      description = ''
        IPv4 addresses or CIDRs allowed to reach port 4444: the reverse proxy
        doing forward_auth and the host. Containers on the same bridge are
        switched past the host's forward rules, so this is the only check
        against them. Empty leaves the port open to everyone.
      '';
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "code-server";
    inherit cfg;
    innerConfig =
      { pkgs, ... }:
      {
        users.users.${cfg.user} = {
          isNormalUser = true;
          uid = 1000;
          extraGroups = [ "users" ];
        };

        system.activationScripts.code-server-settings = {
          text = ''
            mkdir -p /home/${cfg.user}/.local/share/code-server/User
            ln -sf ${pkgs.writeText "code-server-settings.json" (builtins.toJSON commonData.settings)} /home/${cfg.user}/.local/share/code-server/User/settings.json
            chown -R ${cfg.user}:users /home/${cfg.user}/.local
          '';
        };

        # No login of its own: Caddy forward_auth gates it, and only
        # allowedSources may connect.
        services.code-server = {
          enable = true;
          inherit (cfg) user;
          group = "users";
          host = "0.0.0.0";
          auth = "none";
          disableTelemetry = true;
        };
        networking.firewall = {
          allowedTCPPorts = lib.mkIf (cfg.allowedSources == [ ]) [ 4444 ];
          extraInputRules = lib.concatMapStrings (
            src: "ip saddr ${src} tcp dport 4444 accept\n"
          ) cfg.allowedSources;
        };
      };
    bindMounts = {
      "/home/${cfg.user}/Develop" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    };
  });
}
