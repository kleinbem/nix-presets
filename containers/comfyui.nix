_:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.comfyui;
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
      default = true;
      description = "Start the container automatically on boot.";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers.containers.comfyui = {
      image = "docker.io/yanwk/comfyui-boot:xpu";
      inherit (cfg) autoStart;
      ports = [ "8188:8188" ];
      environment = {
        CLI_ARGS = "--listen 0.0.0.0";
      };
      volumes = [
        "${cfg.hostDataDir}:/home/runner/ComfyUI"
      ];
      extraOptions = [
        "--net=cbr0"
        "--ip=${lib.head (lib.splitString "/" cfg.ip)}"
        "--security-opt=no-new-privileges"
      ]
      ++ (lib.optionals cfg.enableGPU [
        "--device=/dev/dri:/dev/dri"
      ])
      ++ (lib.optionals cfg.enableAudio [
        "--device=/dev/snd:/dev/snd"
      ])
      ++ (lib.optionals cfg.enableVideo [
        "--device=/dev/video0:/dev/video0"
        "--device=/dev/video1:/dev/video1"
      ]);
    };

    systemd.services.podman-comfyui = {
      after = [ "podman-network-cbr0.service" ];
      requires = [ "podman-network-cbr0.service" ];
      serviceConfig = {
        MemoryMax = lib.mkIf (cfg.memoryLimit != null) cfg.memoryLimit;
        Environment = [ "TMPDIR=/var/lib/images/podman/tmp" ];
      };
    };
  };
}
