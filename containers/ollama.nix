{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.ollama;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.ollama = {
    enable = lib.mkEnableOption "Native Ollama Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "40G"; # Models can be huge
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "ollama";
    inherit cfg;

    # Needs a lot of time to start if loading huge models
    timeout = "5m";

    innerConfig = _: {
      services.ollama = {
        enable = true;
        host = "0.0.0.0";
        home = "/var/lib/ollama";
        models = "/var/lib/ollama/models";
        environmentVariables = {
          OLLAMA_KEEP_ALIVE = "-1";
        };
      };

      systemd.services.ollama = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          DynamicUser = lib.mkForce false;
          User = "root";
          Group = "root";
          # MemoryHigh = "32G";
          # MemoryMax = "40G";
        };
      };

      networking.firewall.allowedTCPPorts = [ 11434 ];
    };

    bindMounts = {
      "/var/lib/ollama" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    };
  });
}
