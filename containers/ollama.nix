{ self }:
{
  config,
  lib,
  ...
}:

let
  cfg = config.my.containers.ollama;
  mkContainer = self.lib.mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.ollama = {
    enable = lib.mkEnableOption "Ollama Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    enableGPU = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable /dev/dri GPU hardware acceleration for the container.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "12G";
    };
  } // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer { inherit config;
    name = "ollama";
    cfg = cfg;
    innerConfig = {
      nixpkgs.config.allowUnfree = true;
      services.ollama = {
        enable = true;
        host = "0.0.0.0";
        port = 11434;
      };
      systemd.services.ollama.serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = lib.mkForce "root";
        Group = lib.mkForce "root";
      };
      networking.firewall.allowedTCPPorts = [ 11434 ];
    };
    bindMounts = {
      "/var/lib/ollama" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    } // lib.optionalAttrs cfg.enableGPU {
      "/dev/dri/renderD128" = {
        hostPath = "/dev/dri/renderD128";
        isReadOnly = false;
      };
    };
  });
}
