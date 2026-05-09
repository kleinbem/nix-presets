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
      default = "pick";
    };
    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
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

        services.code-server = {
          enable = true;
          inherit (cfg) user;
          group = "users";
          host = "0.0.0.0";
          auth = "none";
          disableTelemetry = true;
        };
        networking.firewall.allowedTCPPorts = [
          8080
          4444
        ];
      };
    bindMounts = {
      "/home/${cfg.user}/Develop" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    };
  });
}
