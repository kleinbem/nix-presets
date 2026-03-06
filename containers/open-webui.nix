{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.open-webui;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.open-webui = {
    enable = lib.mkEnableOption "Open WebUI Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    ollamaUrl = lib.mkOption { type = lib.types.str; };
    vllmUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path on the host to environment file containing LANGFUSE_SECRET_KEY, LANGFUSE_PUBLIC_KEY, and LANGFUSE_HOST";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "4G";
    };
    enableAudio = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable /dev/snd ALSA hardware pass-through for local Whisper STT & TTS.";
    };
    enableVideo = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable /dev/video* hardware pass-through for direct webcam integration.";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "open-webui";
    inherit cfg;
    innerConfig = {
      nixpkgs.config.allowUnfree = true;
      services.open-webui = {
        enable = true;
        host = "0.0.0.0";
        port = 8080;
        environmentFile = "/run/secrets/openwebui.env";
        environment = {
          OLLAMA_BASE_URL = cfg.ollamaUrl;
          OPENAI_API_BASE_URL = if cfg.vllmUrl != null then cfg.vllmUrl else "";
          WEBUI_AUTH = "True";
        };
      };
      systemd.services.open-webui.serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = lib.mkForce "root";
        Group = lib.mkForce "root";
        CapabilityBoundingSet = lib.mkForce [
          "CAP_CHOWN"
          "CAP_FOWNER"
          "CAP_DAC_OVERRIDE"
          "CAP_SETUID"
          "CAP_SETGID"
        ];
        SystemCallFilter = lib.mkForce [
          "@system-service"
          "@privileged"
        ];
        NoNewPrivileges = lib.mkForce false;
        PrivateUsers = lib.mkForce false;
      };
      networking.firewall.allowedTCPPorts = [ 8080 ];
      environment.systemPackages = [
        pkgs.python313Packages.passlib
        pkgs.python313Packages.bcrypt
      ];
    };
    bindMounts = {
      "/var/lib/open-webui" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    }
    // lib.optionalAttrs (cfg.secretsFile != null) {
      "/run/secrets/openwebui.env" = {
        hostPath = cfg.secretsFile;
        isReadOnly = true;
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
