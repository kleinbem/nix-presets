{ self, inputs }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.openclaw;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.openclaw = {
    enable = lib.mkEnableOption "OpenClaw Personal AI Agent Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    vllmUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Internal URL to the local vLLM/OpenAI instance";
    };
    ollamaUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Internal URL to the local Ollama instance";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "4G";
    };
    enableAudio = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable /dev/snd ALSA hardware pass-through for ambient listening & TTS.";
    };
    enableVideo = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable /dev/video* hardware pass-through for ambient visual perception.";
    };
    enableUSB = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable /dev/bus/usb hardware pass-through for TPU accelerators and Home Automation devices.";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "openclaw";
    inherit cfg;
    innerConfig = {
      # 1. Import the official OpenClaw NixOS module inside the container
      imports = [ inputs.openclaw.nixosModules.openclaw-gateway ];

      # Core primitives for Pi's subtractive design (read, write, bash)
      environment.systemPackages = with config.nixpkgs.pkgs; [
        git
        bash
        curl
        jq
        python3
        nodejs
        nix
      ];

      # 2. Configure the agent
      services.openclaw-gateway = {
        enable = true;
        # Wait for the configuration to be added by the user
      };

      # 3. Restrict networking so it cannot be reached from the outside
      networking.firewall.enable = true;
      # Allow outbound traffic to Internet and Ollama on bridge
    };
    bindMounts = {
      # State directory for conversations, configs, and plugins
      "/var/lib/openclaw" = {
        hostPath = cfg.hostDataDir;
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
    }
    // lib.optionalAttrs cfg.enableUSB {
      "/dev/bus/usb" = {
        hostPath = "/dev/bus/usb";
        isReadOnly = false;
      };
    };
  });
}
