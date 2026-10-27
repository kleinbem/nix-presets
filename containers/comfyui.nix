{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.comfyui;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.comfyui = {
    enable = lib.mkEnableOption "ComfyUI Visual Generation Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    enableGPU = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable /dev/dri GPU hardware acceleration for the container.";
    };
    enableAudio = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable /dev/snd ALSA hardware pass-through for Whisper & TTS nodes.";
    };
    enableVideo = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable /dev/video* hardware pass-through for visual workflows.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "12G";
    };
    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Start the container automatically on boot.";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "comfyui";
    inherit cfg;
    usesPodman = true;
    inherit (cfg) enableGPU enableAudio enableVideo;
    subDirs = [ "ComfyUI" ];
    innerConfig = {
      virtualisation.oci-containers = {
        backend = "podman";
        containers.comfyui = {
          image = "docker.io/yanwk/comfyui-boot:xpu";
          ports = [ "8188:8188" ];
          environment = {
            CLI_ARGS = "--listen 0.0.0.0";
          };
          volumes = [
            "${cfg.hostDataDir}/ComfyUI:/home/runner/ComfyUI"
          ];
          extraOptions = [
            "--device=/dev/dri:/dev/dri"
          ];
        };
      };

      networking.firewall.allowedTCPPorts = [ 8188 ];
    };
  });
}
