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
  options.my.desktop.bottles = {
    enable = lib.mkEnableOption "Bottles (Wine prefix manager) for running Windows executables";

    gamemodeUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Users added to the `gamemode` group, which gamemoded requires before it
        will renice processes. Toggle GameMode per bottle in its settings.
      '';
    };
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

    # Most Windows software is still 32-bit, and DXVK/VKD3D need the 32-bit
    # Vulkan ICD too.
    hardware.graphics = {
      enable = true;
      enable32Bit = true;
    };

    # Wine 10+ runners use /dev/ntsync for NT sync primitives (faster and more
    # correct than esync/fsync). Harmless where it's built in (=y).
    boot.kernelModules = [ "ntsync" ];

    programs.gamemode = {
      enable = true;
      settings.general = {
        renice = 10;
        inhibit_screensaver = 1;
      };
    };
    users.groups.gamemode.members = cfg.gamemodeUsers;
  };
}
