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

  # Optimized package for Orin Nano (CUDA + ARM NEON)
  # We use pkgs.llama-cpp from the host's pkgs to ensure CUDA compatibility.
  # We set cpuArchDynamicDispatch = false because CUDA pins the host compiler to GCC 13,
  # while armv9.2+sme target in cpuArchDynamicDispatch requires GCC >= 14.
  llamaPackage = pkgs.llama-cpp.override {
    cudaSupport = true;
    cpuArchDynamicDispatch = false;
  };
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
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "llama-cpp";
    cfg = cfg // {
      extraAllowedDevices = [
        { node = "/dev/nvmap"; modifier = "rw"; }
        { node = "/dev/dri"; modifier = "rw"; }
        { node = "/dev/dri/renderD128"; modifier = "rw"; }
        { node = "/dev/dri/card0"; modifier = "rw"; }
        { node = "/dev/nvgpu/igpu0/as"; modifier = "rw"; }
        { node = "/dev/nvgpu/igpu0/channel"; modifier = "rw"; }
        { node = "/dev/nvgpu/igpu0/ctrl"; modifier = "rw"; }
        { node = "/dev/nvgpu/igpu0/power"; modifier = "rw"; }
        { node = "/dev/nvgpu/igpu0/sched"; modifier = "rw"; }
        { node = "/dev/nvgpu/igpu0/tsg"; modifier = "rw"; }
        { node = "/dev/nvhost-ctrl-gpu"; modifier = "rw"; }
        { node = "/dev/nvhost-gpu"; modifier = "rw"; }
        { node = "/dev/nvhost-as-gpu"; modifier = "rw"; }
        { node = "/dev/nvhost-prof-gpu"; modifier = "rw"; }
      ];
    };

    enableGPU = true;
    timeout = "5m";

    innerConfig = _: {
      # ─── Distroless-style Minimalism ──────────────────────────
      # Disable all unnecessary NixOS features to reduce surface area
      documentation.enable = false;
      programs.command-not-found.enable = false;
      services.udisks2.enable = false;
      boot.isContainer = true;

      # Ensure we have the right license for CUDA components
      nixpkgs = {
        config = {
          allowUnfree = true;
          allowUnfreePredicate = _: true;
        };
      };

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
            + "--n-gpu-layers ${toString cfg.gpuLayers} "
            + "--ctx-size ${toString cfg.contextSize} "
            + "--flash-attn auto "
            + "--cache-type-k q4_0 " # KV Cache quantization (essential for 8GB)
            + "--cache-type-v q4_0";

          Restart = "always";
          RestartSec = "5s";

          # Hardening & Minimalism
          DynamicUser = true;
          SupplementaryGroups = [ "video" "render" ];
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
      "/run/opengl-driver" = {
        hostPath = "/run/opengl-driver";
        isReadOnly = true;
      };
      "/dev/dri" = {
        hostPath = "/dev/dri";
        isReadOnly = false;
      };
      "/dev/nvmap" = {
        hostPath = "/dev/nvmap";
        isReadOnly = false;
      };
      "/dev/nvgpu/igpu0/as" = { hostPath = "/dev/nvgpu/igpu0/as"; isReadOnly = false; };
      "/dev/nvgpu/igpu0/channel" = { hostPath = "/dev/nvgpu/igpu0/channel"; isReadOnly = false; };
      "/dev/nvgpu/igpu0/ctrl" = { hostPath = "/dev/nvgpu/igpu0/ctrl"; isReadOnly = false; };
      "/dev/nvgpu/igpu0/power" = { hostPath = "/dev/nvgpu/igpu0/power"; isReadOnly = false; };
      "/dev/nvgpu/igpu0/sched" = { hostPath = "/dev/nvgpu/igpu0/sched"; isReadOnly = false; };
      "/dev/nvgpu/igpu0/tsg" = { hostPath = "/dev/nvgpu/igpu0/tsg"; isReadOnly = false; };
      "/dev/nvhost-ctrl-gpu" = { hostPath = "/dev/nvhost-ctrl-gpu"; isReadOnly = false; };
      "/dev/nvhost-gpu" = { hostPath = "/dev/nvhost-gpu"; isReadOnly = false; };
      "/dev/nvhost-as-gpu" = { hostPath = "/dev/nvhost-as-gpu"; isReadOnly = false; };
      "/dev/nvhost-prof-gpu" = { hostPath = "/dev/nvhost-prof-gpu"; isReadOnly = false; };
    };
  });
}
