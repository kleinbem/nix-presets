{ self }:
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.my.containers.llama-cpp;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };

  # CUDA build for the Orin Nano. Dynamic dispatch is off because CUDA pins
  # GCC 13 and its armv9.2+sme variant needs GCC 14. Drop once nixpkgs'
  # llama-cpp includes ggml-org/llama.cpp#26103 (probes each ARM variant).
  llamaPackage =
    if cfg.enableCuda then
      pkgs.llama-cpp.override {
        cudaSupport = true;
        cpuArchDynamicDispatch = false;
      }
    else
      pkgs.llama-cpp;

  # Jetson (nvgpu/nvhost) device nodes the CUDA runtime opens.
  gpuDevices = [
    "/dev/nvmap"
    "/dev/nvgpu/igpu0/as"
    "/dev/nvgpu/igpu0/channel"
    "/dev/nvgpu/igpu0/ctrl"
    "/dev/nvgpu/igpu0/power"
    "/dev/nvgpu/igpu0/sched"
    "/dev/nvgpu/igpu0/tsg"
    "/dev/nvhost-ctrl-gpu"
    "/dev/nvhost-gpu"
    "/dev/nvhost-as-gpu"
    "/dev/nvhost-prof-gpu"
  ];
in
{
  options.my.containers.llama-cpp = {
    enable = lib.mkEnableOption "Lean llama.cpp Server (Distroless-style)";
    ip = lib.mkOption { type = lib.types.str; };
    modelPath = lib.mkOption {
      type = lib.types.str;
      description = "Path to the .gguf model file on the host.";
    };
    contextSize = lib.mkOption {
      type = lib.types.int;
      default = 4096;
      description = "Context window size (impacts RAM).";
    };
    gpuLayers = lib.mkOption {
      type = lib.types.int;
      default = 99;
      description = "Number of layers to offload to GPU.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "6G";
      description = "systemd MemoryMax for the container (e.g. \"6G\"). null = unbounded.";
    };
    port = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = 11434;
      description = "Host port to forward to the container.";
    };
    enableCuda = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable CUDA acceleration. Defaults to false on Jetson to avoid PTX toolchain mismatch between CUDA 12.9 and driver 540.5.0.";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "llama-cpp";
    cfg = cfg // {
      extraAllowedDevices = lib.optionals cfg.enableCuda (
        map
          (node: {
            inherit node;
            modifier = "rw";
          })
          (
            [
              "/dev/dri"
              "/dev/dri/renderD128"
              "/dev/dri/card0"
            ]
            ++ gpuDevices
          )
      );
    };

    enableGPU = cfg.enableCuda;
    timeout = "5m";

    innerConfig = _: {
      # ─── Distroless-style Minimalism ──────────────────────────
      # Disable all unnecessary NixOS features to reduce surface area
      documentation.enable = false;
      programs.command-not-found.enable = false;
      services.udisks2.enable = false;
      boot.isContainer = true;

      # ─── Lean Inference Service ──────────────────────────────
      systemd.services.llama-server = {
        description = "Ultra-lean llama.cpp server";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          # Run directly with optimized flags
          ExecStart =
            "${llamaPackage}/bin/llama-server "
            + "--model /models/model.gguf "
            + "--host 0.0.0.0 "
            + "--port 11434 "
            + (if cfg.enableCuda then "--n-gpu-layers ${toString cfg.gpuLayers} " else "--n-gpu-layers 0 ")
            + "--ctx-size ${toString cfg.contextSize} "
            + "--flash-attn auto "
            + "--cache-type-k q4_0 " # KV Cache quantization (essential for 8GB)
            + "--cache-type-v q4_0";

          Restart = "always";
          RestartSec = "5s";

          # Hardening & Minimalism
          DynamicUser = true;
          SupplementaryGroups = lib.optionals cfg.enableCuda [
            "video"
            "render"
          ];
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
        };
      };

      networking.firewall.allowedTCPPorts = [ 11434 ];
    };

    bindMounts = {
      "/models/model.gguf" = {
        hostPath = cfg.modelPath;
        isReadOnly = true;
      };
    }
    // lib.optionalAttrs cfg.enableCuda (
      {
        "/run/opengl-driver" = {
          hostPath = "/run/opengl-driver";
          isReadOnly = true;
        };
      }
      // lib.genAttrs gpuDevices (dev: {
        hostPath = dev;
        isReadOnly = false;
      })
    );
  });
}
