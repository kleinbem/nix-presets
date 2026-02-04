{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.my.containers.ollama;
in
{
  options.my.containers.ollama = {
    enable = lib.mkEnableOption "Ollama Container";
    ip = lib.mkOption {
      type = lib.types.str;
      description = "IP address for the container";
    };
    hostBridge = lib.mkOption {
      type = lib.types.str;
      default = "incusbr0";
      description = "Host bridge interface";
    };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      description = "Host directory to bind mount for model storage";
    };
  };

  config = lib.mkIf cfg.enable {
    containers.ollama = {
      autoStart = true;
      privateNetwork = true;
      hostBridge = cfg.hostBridge;
      localAddress = cfg.ip;

      bindMounts = {
        "/var/lib/ollama" = {
          hostPath = cfg.hostDataDir;
          isReadOnly = false;
        };
      };

      config =
        { pkgs, ... }:
        {
          system.stateVersion = "24.05";
          nixpkgs.config.allowUnfree = true;

          services.ollama = {
            enable = true;
            host = "0.0.0.0"; # Listen on all interfaces so host/other containers can reach it
            port = 11434;
            # acceleration = "cuda"; # Deprecated
            package = pkgs.ollama-cuda; # Explicitly use CUDA enabled package
          };
          
          # Allow firewall access
          networking.firewall.allowedTCPPorts = [ 11434 ];
        };
    };
  };
}
