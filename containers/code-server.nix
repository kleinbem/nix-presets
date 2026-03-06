{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.code-server;
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
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "code-server";
    inherit cfg;
    innerConfig = {
      users.users.${cfg.user} = {
        isNormalUser = true;
        uid = 1000;
        extraGroups = [ "users" ];
      };

      services.code-server = {
        enable = true;
        inherit (cfg) user;
        group = "users";
        host = "0.0.0.0";
        auth = "none";
        disableTelemetry = true;
      };
      networking.firewall.allowedTCPPorts = [ 4444 ];
    };
    bindMounts = {
      "/home/${cfg.user}/Develop" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    };
  });
}
