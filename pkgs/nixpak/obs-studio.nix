{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
  sandboxedXdgUtils = pkgs.callPackage ../../nixpak/xdg-utils.nix { };
in
utils.mkSandboxed {
  package = pkgs.obs-studio;
  name = "obs-studio";
  executableName = "obs";
  extraBinNames = [ "obs" ];
  configDir = "obs-studio";
  displayName = "OBS Studio";
  extraPackages = [ sandboxedXdgUtils ];
  presets = [
    "wayland"
    "gpu"
    "audio"
    "network"
  ];
  extraPerms =
    { sloth, ... }:
    {
      # Wayland screen/window capture and camera go through PipeWire + portals
      # (com.obsproject.Studio architecture), so no X11 or /dev/video* binds.
      dbus.policies = {
        "org.freedesktop.Notifications" = "talk";
        # ScreenCast, Camera, FileChooser, OpenURI
        "org.freedesktop.portal.*" = "talk";
        "org.kde.StatusNotifierWatcher" = "talk"; # tray icon
        "org.freedesktop.ScreenSaver" = "talk"; # inhibit idle while recording
      };
      bubblewrap.bind = {
        rw = [
          # Default recording output directory
          (sloth.concat' sloth.homeDir "/Videos")
        ];
        ro = [
          # Overlays, images, and audio assets
          (sloth.concat' sloth.homeDir "/Pictures")
          (sloth.concat' sloth.homeDir "/Music")
        ];
      };
    };
}
