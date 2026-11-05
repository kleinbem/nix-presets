{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.my.desktop.bottles;
in
{
  # Tuned for running Windows *applications*, not games: no GameMode/renice.
  options.my.desktop.bottles = {
    enable = lib.mkEnableOption "Bottles (Wine prefix manager) for running Windows executables";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      # Native nixpkgs build (FHS-wrapped, so downloaded runners like
      # soda/wine-ge/kron4ek find their libs) rather than the Flatpak: no
      # sandbox, so .exe files anywhere in $HOME open without portal
      # permission juggling. The popup only says "unsupported outside Flatpak".
      (pkgs.bottles.override { removeWarningPopup = true; })
      pkgs.vulkan-tools # vulkaninfo, to check DXVK/VKD3D have a usable device
    ];

    # Many installers and older apps are 32-bit, and Wine's Direct3D-on-Vulkan
    # layers (DXVK/VKD3D) need the 32-bit Vulkan ICD for them.
    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };

    # Wine 10+ runners use /dev/ntsync for NT sync primitives (faster and more
    # correct than esync/fsync for multithreaded apps). Harmless where it's
    # built in (=y).
    boot.kernelModules = [ "ntsync" ];
  };
}
