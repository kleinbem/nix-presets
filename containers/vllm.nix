_:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.vllm;
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
    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Start the container automatically on boot.";
    };
    enableAudio = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable /dev/snd ALSA hardware pass-through for Whisper & TTS nodes.";
    };
    image = lib.mkOption {
      type = lib.types.str;
      default = "vllm/vllm-openai:latest";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "16G";
    };
    memorySwapMax = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Maximum swap memory allowed for the container.";
    };
    model = lib.mkOption {
      type = lib.types.str;
      default = "google/gemma-2b";
      description = "The HuggingFace model ID to serve.";
    };
    gpuMemoryUtilization = lib.mkOption {
      type = lib.types.float;
      default = 0.9;
      description = "The fraction of GPU memory to reserve for the KV cache.";
    };
    maxModelLen = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Maximum context length. If null, use model default.";
    };
    device = lib.mkOption {
      type = lib.types.enum [
        "cuda"
        "xpu"
        "cpu"
        "openvino"
        "neuron"
        "tpu"
      ];
      default = "cuda";
      description = "The hardware device to use for inference.";
    };
    enforceEager = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enforce eager execution (saves memory, slower).";
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra arguments to pass to the vLLM server.";
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path on the host to a .env file containing HUGGING_FACE_HUB_TOKEN";
    };
    openvinoDevice = lib.mkOption {
      type = lib.types.str;
      default = "GPU";
      description = "The OpenVINO device to use (e.g., GPU, CPU).";
    };
    openvinoKvCacheSpace = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "The amount of space to reserve for the OpenVINO KV cache (GB).";
    };
    quantization = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Quantization method (e.g., gptq, awq).";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers.containers.vllm = {
      inherit (cfg) image autoStart;
      ports = [ "8000:8000" ];
      environment =
        (lib.optionalAttrs (cfg.device == "openvino") {
          VLLM_OPENVINO_DEVICE = cfg.openvinoDevice;
          VLLM_OPENVINO_KVCACHE_SPACE = toString cfg.openvinoKvCacheSpace;
        })
        // (lib.optionalAttrs (cfg.device == "cpu") {
          VLLM_CPU_KVCACHE_SPACE = "8"; # Cap cache to prevent OOM hang
        })
        // (lib.optionalAttrs (cfg.device == "xpu") {
          VLLM_SKIP_XPU_DISTRIBUTED = "1";
          VLLM_SKIP_P2P_CHECK = "1";
          IPEX_XPU_ONEDNN_LAYOUT = "1";
        });
      environmentFiles = lib.optional (cfg.secretsFile != null) cfg.secretsFile;
      volumes = [
        "${cfg.hostDataDir}:/root/.cache/huggingface"
      ];
      cmd = [
        "--model"
        cfg.model
        "--host"
        "0.0.0.0"
        "--port"
        "8000"
      ]
      ++ (lib.optionals (cfg.device != "cpu") [
        "--gpu-memory-utilization"
        (toString cfg.gpuMemoryUtilization)
      ])
      ++ (lib.optionals
        (
          !lib.elem cfg.device [
            "cpu"
            "openvino"
          ]
        )
        [
          "--device"
          cfg.device
        ]
      )
      ++ (lib.optionals (cfg.maxModelLen != null) [
        "--max-model-len"
        (toString cfg.maxModelLen)
      ])
      ++ (lib.optionals (cfg.quantization != null) [
        "--quantization"
        cfg.quantization
      ])
      ++ (lib.optional cfg.enforceEager "--enforce-eager")
      ++ cfg.extraArgs;
      extraOptions = [
        "--ipc=host"
        "--net=cbr0"
        "--privileged"
        "--security-opt=label=disable"
        "--security-opt=no-new-privileges"
        "--ip=${lib.head (lib.splitString "/" cfg.ip)}"
      ]
      ++ (lib.optionals (cfg.device != "cpu") [
        "--device=/dev/dri"
        "--volume=/sys:/sys:ro"
        "--volume=/dev:/dev"
        "--volume=/run/udev:/run/udev:ro"
      ])
      ++ (lib.optionals cfg.enableAudio [
        "--device=/dev/snd"
      ]);
    };

    systemd.services.podman-vllm = {
      after = [ "podman-network-cbr0.service" ];
      requires = [ "podman-network-cbr0.service" ];
      serviceConfig = {
        MemoryMax = lib.mkIf (cfg.memoryLimit != null) cfg.memoryLimit;
        MemorySwapMax = lib.mkIf (cfg.memorySwapMax != null) cfg.memorySwapMax;
        Environment = [ "TMPDIR=/var/lib/images/podman/tmp" ];
      };
    };
  };
}
