{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  cfg = config.services.android-desktop-emulator;

  # Dynamic SDK based on configuration
  androidSdk = pkgs.androidenv.composeAndroidPackages {
    cmdLineToolsVersion = "13.0";
    platformToolsVersion = "36.0.1";
    buildToolsVersions = [ "36.0.0" ];
    includeEmulator = true;
    includeSystemImages = true;
    systemImageTypes = [ cfg.systemImageType ];
    abiVersions = [ cfg.abiVersion ];
    platformVersions = [ cfg.platformVersion ];
  };

  # Construct the system image string for the emulator
  systemImageString = "system-images;android-${cfg.platformVersion};${cfg.systemImageType};${cfg.abiVersion}";

  # Helper to resolve script path
  scriptPath = ../files/scripts/android;

  # Launcher script wrappers
  launchScript = pkgs.writeShellApplication {
    name = "launch-android-daily-driver";
    runtimeInputs = [
      androidSdk.androidsdk
      pkgs.jdk
      pkgs.steam-run
      pkgs.android-tools
      pkgs.scrcpy
    ];
    text = ''
      export ANDROID_SDK_ROOT="${androidSdk.androidsdk}/libexec/android-sdk"
      export ANDROID_HOME="$ANDROID_SDK_ROOT"
      export JAVA_HOME="${pkgs.jdk}/lib/openjdk"
      export ANDROID_AVD_NAME="${cfg.avdName}"
      export ANDROID_SYSTEM_IMAGE="${systemImageString}"
      export ANDROID_EMULATOR_GPU_MODE="${cfg.gpuMode}"
      export ANDROID_EMULATOR_MEMORY="${toString cfg.memorySize}"
      export ANDROID_EMULATOR_FLAGS="${cfg.extraEmulatorFlags}"
      ${builtins.readFile (scriptPath + "/launch-android-desktop.sh")}
    '';
  };

  launchVaultScript = pkgs.writeShellApplication {
    name = "launch-android-vault";
    runtimeInputs = [
      androidSdk.androidsdk
      pkgs.jdk
      pkgs.steam-run
      pkgs.android-tools
    ];
    text = ''
      export ANDROID_SDK_ROOT="${androidSdk.androidsdk}/libexec/android-sdk"
      export ANDROID_HOME="$ANDROID_SDK_ROOT"
      export JAVA_HOME="${pkgs.jdk}/lib/openjdk"
      export ANDROID_VAULT_AVD_NAME="${cfg.vaultAvdName}"
      export ANDROID_SYSTEM_IMAGE="${systemImageString}"
      export ANDROID_EMULATOR_GPU_MODE="${cfg.gpuMode}"
      export ANDROID_EMULATOR_MEMORY="${toString cfg.memorySize}"
      export ANDROID_EMULATOR_FLAGS="${cfg.extraEmulatorFlags}"
      ${builtins.readFile (scriptPath + "/launch-vault.sh")}
    '';
  };

  emulatorDaemonScript = pkgs.writeShellApplication {
    name = "launch-emulator-daemon";
    runtimeInputs = [
      androidSdk.androidsdk
      pkgs.jdk
      pkgs.procps
      pkgs.steam-run
      pkgs.qemu_kvm
    ];
    text = ''
      export ANDROID_SDK_ROOT="${androidSdk.androidsdk}/libexec/android-sdk"
      export ANDROID_HOME="$ANDROID_SDK_ROOT"
      export JAVA_HOME="${pkgs.jdk}/lib/openjdk"

      # Runtime Config
      export ANDROID_EMULATOR_GPU_MODE="${cfg.gpuMode}"
      export ANDROID_EMULATOR_MEMORY="${toString cfg.memorySize}"
      export ANDROID_EMULATOR_FLAGS="${cfg.extraEmulatorFlags}"
      export ANDROID_EMULATOR_HEADLESS="${if cfg.headless then "true" else "false"}"

      # Launch the daemon script
      ${builtins.readFile (scriptPath + "/launch-emulator-daemon.sh")} "$@"
    '';
  };

  scrcpyClient = pkgs.writeShellApplication {
    name = "launch-scrcpy-client";
    runtimeInputs = [
      pkgs.android-tools
      pkgs.scrcpy
    ];
    text = ''
      ${builtins.readFile (scriptPath + "/launch-scrcpy-client.sh")} "$@"
    '';
  };

in
{
  options.services.android-desktop-emulator = {
    enable = lib.mkEnableOption "Android Desktop Emulator Support";

    user = lib.mkOption {
      type = lib.types.str;
      description = "The user to add to adbusers and kvm groups.";
    };

    platformVersion = lib.mkOption {
      type = lib.types.str;
      default = "36";
      description = "Android Platform Version (e.g. 36)";
    };

    abiVersion = lib.mkOption {
      type = lib.types.str;
      default = "x86_64";
      description = "Android ABI Version (e.g. x86_64)";
    };

    systemImageType = lib.mkOption {
      type = lib.types.str;
      default = "google_apis_playstore";
      description = "Android System Image Type (e.g. google_apis_playstore)";
    };

    avdName = lib.mkOption {
      type = lib.types.str;
      default = "NixIntegratedDev";
      description = "Name of the Android Virtual Device to create/launch";
    };

    vaultAvdName = lib.mkOption {
      type = lib.types.str;
      default = "MySecureVault";
      description = "Name of the Vault Android Virtual Device";
    };

    gpuMode = lib.mkOption {
      type = lib.types.str;
      default = "swiftshader_indirect";
      description = "GPU emulation mode (e.g. host, swiftshader_indirect, auto)";
    };

    memorySize = lib.mkOption {
      type = lib.types.int;
      default = 4096;
      description = "RAM size for the emulator in MB";
    };

    extraEmulatorFlags = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Extra flags to pass to the emulator command";
    };

    headless = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run the emulator daemon in headless mode (no window)";
    };
  };

  config = lib.mkIf cfg.enable {
    # System Requirements
    # programs.adb.enable = true; # Deprecated in systemd 258
    users.users.${cfg.user}.extraGroups = [
      "adbusers"
      "kvm"
      "video"
      "audio"
    ];

    # Udev rules for Android devices

    # Enable Unfree for Google APIs image
    nixpkgs.config.allowUnfree = true;
    nixpkgs.config.android_sdk.accept_license = true;

    # Systemd User Service for Emulator Daemon
    systemd.user.services.android-emulator = {
      description = "Background Android Emulator for Integrated Workspace";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      environment = {
        ANDROID_AVD_NAME = cfg.avdName;
        ANDROID_SYSTEM_IMAGE = systemImageString;
        ANDROID_EMULATOR_GPU_MODE = cfg.gpuMode;
        ANDROID_EMULATOR_MEMORY = toString cfg.memorySize;
        ANDROID_EMULATOR_FLAGS = cfg.extraEmulatorFlags;
        ANDROID_EMULATOR_HEADLESS = if cfg.headless then "true" else "false";
      };
      serviceConfig = {
        ExecStart = "${emulatorDaemonScript}/bin/launch-emulator-daemon";
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStopSec = "30s";
      };
    };

    # Install launcher scripts and client
    environment.systemPackages = [
      pkgs.android-tools # Provides adb
      pkgs.steam-run
      launchScript
      launchVaultScript
      scrcpyClient
      # Audio/Video Support
      pkgs.alsa-utils
      pkgs.v4l-utils
      # Biometric Simulation
      (pkgs.writeShellScriptBin "simulate-fingerprint" (
        builtins.readFile (scriptPath + "/simulate-fingerprint.sh")
      ))
    ];
  };
}
