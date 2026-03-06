{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.vllm;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.vllm = {
    enable = lib.mkEnableOption "vLLM High-Throughput Inference Container";
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
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "16G";
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path on the host to a .env file containing HUGGING_FACE_HUB_TOKEN";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "vllm";
    inherit cfg;
    innerConfig = {
      virtualisation = {
        oci-containers.backend = "podman";
        podman.enable = true;
        oci-containers.containers.vllm = {
          image = "vllm/vllm-openai:latest";
          ports = [ "8000:8000" ];
          environmentFiles = [ "/run/secrets/vllm.env" ];
          volumes = [
            "/var/lib/vllm:/root/.cache/huggingface"
          ];
          extraOptions = [
            "--ipc=host"
          ]
          ++ (lib.optionals cfg.enableGPU [
            "--device=/dev/dri"
          ])
          ++ (lib.optionals cfg.enableAudio [
            "--device=/dev/snd"
          ]);
        };
      };

      networking.firewall.allowedTCPPorts = [ 8000 ];
    };
    bindMounts = {
      "/var/lib/vllm" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    }
    // lib.optionalAttrs (cfg.secretsFile != null) {
      "/run/secrets/vllm.env" = {
        hostPath = cfg.secretsFile;
        isReadOnly = true;
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
    };
  });
}
