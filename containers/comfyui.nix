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
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "comfyui";
    inherit cfg;
    innerConfig = {
      virtualisation = {
        oci-containers.backend = "podman";
        podman.enable = true;
        oci-containers.containers.comfyui = {
          image = "yanwk/comfyui-boot:latest";
          ports = [ "8188:8188" ];
          environment = {
            CLI_ARGS = "--listen 0.0.0.0";
          };
          volumes = [
            "/var/lib/comfyui:/home/runner/ComfyUI"
          ];
          extraOptions =
            (lib.optionals cfg.enableGPU [
              "--device=/dev/dri"
            ])
            ++ (lib.optionals cfg.enableAudio [
              "--device=/dev/snd"
            ])
            ++ (lib.optionals cfg.enableVideo [
              "--device=/dev/video0"
              "--device=/dev/video1"
            ]);
        };
      };

      networking.firewall.allowedTCPPorts = [ 8188 ];
    };
    bindMounts = {
      "/var/lib/comfyui" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    }
    // lib.optionalAttrs cfg.enableGPU {
      "/dev/dri" = {
        hostPath = "/dev/dri";
        isReadOnly = false;
      };
    }
    // lib.optionalAttrs cfg.enableAudio {
      "/dev/snd" = {
        hostPath = "/dev/snd";
        isReadOnly = false;
      };
    }
    // lib.optionalAttrs cfg.enableVideo {
      "/dev/video0" = {
        hostPath = "/dev/video0";
        isReadOnly = false;
      };
      "/dev/video1" = {
        hostPath = "/dev/video1";
        isReadOnly = false;
      };
    };
  });
}
