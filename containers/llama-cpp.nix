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
  # We use pkgs.llama-cpp from the host's pkgs to ensure CUDA compatibility
  llamaPackage = pkgs.llama-cpp.override {
    cudaSupport = true;
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
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "llama-cpp";
    inherit cfg;

    enableGPU = true;
    timeout = "5m";

    innerConfig = _: {
      # ─── Distroless-style Minimalism ──────────────────────────
      # Disable all unnecessary NixOS features to reduce surface area
      documentation.enable = false;
      programs.command-not-found.enable = false;
      environment.noXlibs = true;
      services.udisks2.enable = false;
      boot.isContainer = true;

      # Ensure we have the right license for CUDA components
      nixpkgs = {
        perl.enable = false;
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
            + "--flash-attn "
            + "--cache-type-k q4_0 " # KV Cache quantization (essential for 8GB)
            + "--cache-type-v q4_0 "
            + "--no-mmap"; # Force load into RAM for predictable performance on Jetson

          Restart = "always";
          RestartSec = "5s";

          # Hardening & Minimalism
          DynamicUser = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          NoNewPrivileges = true;
          CapabilityBoundingSet = ""; # No special caps needed

          # Resource constraints for 8GB RAM
          MemoryHigh = "6.5G";
          MemoryMax = "7.2G";
        };
      };

      networking.firewall.allowedTCPPorts = [ 11434 ];
    };

    bindMounts = {
      "/models/model.gguf" = {
        hostPath = cfg.modelPath;
        isReadOnly = true;
      };
    };
  });
}
