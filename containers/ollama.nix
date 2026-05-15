{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.ollama;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.ollama = {
    enable = lib.mkEnableOption "Native Ollama Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Start the container automatically on boot.";
    };
    acceleration = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "cuda"
          "rocm"
          "vulkan"
        ]
      );
      default = null;
      description = "Hardware acceleration backend (cuda, rocm, vulkan, or null for CPU-only).";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "40G"; # Models can be huge
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkContainer {
        inherit config;
        name = "ollama";
        inherit cfg;

        # GPU pass-through for CUDA/ROCm acceleration
        enableGPU = cfg.acceleration != null;

        # Needs a lot of time to start if loading huge models
        timeout = "5m";

        innerConfig =
          { pkgs, ... }:
          {
            nixpkgs.config.allowUnfree = lib.mkForce true;
            nixpkgs.config.allowUnfreePredicate = lib.mkForce (
              pkg:
              builtins.elem (lib.getName pkg) [
                "ollama-cuda"
                "cuda_cudart"
                "cuda_cccl"
                "cuda_nvcc"
              ]
              || (lib.hasPrefix "cuda" (lib.getName pkg))
            );
            services.ollama = {
              enable = true;
              host = "0.0.0.0";
              home = "/var/lib/ollama";
              models = "/var/lib/ollama/models";
              package =
                if cfg.acceleration == "cuda" then
                  pkgs.ollama-cuda
                else if cfg.acceleration == "rocm" then
                  pkgs.ollama-rocm
                else if cfg.acceleration == "vulkan" then
                  pkgs.ollama-vulkan
                else
                  pkgs.ollama;
              environmentVariables = {
                OLLAMA_KEEP_ALIVE = "-1";
              };
            };

            systemd.services.ollama = {
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                DynamicUser = lib.mkForce false;
                User = "root";
                Group = "root";
                # MemoryHigh = "32G";
                # MemoryMax = "40G";
              };
            };

            networking.firewall.allowedTCPPorts = [ 11434 ];
          };

        bindMounts = {
          "/var/lib/ollama" = {
            hostPath = cfg.hostDataDir;
            isReadOnly = false;
          };
        };
      })
      {
        containers.ollama.config.nixpkgs.config.allowUnfree = lib.mkForce true;
      }
    ]
  );
}
