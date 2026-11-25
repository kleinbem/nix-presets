{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
in
utils.mkSandboxed {
  package = pkgs.mpv;
  name = "mpv";
  configDir = "mpv";
  displayName = "mpv";
  presets = [
    "wayland"
    "gpu"
    "audio"
    "network"
  ];
  extraPerms =
    { sloth, ... }:
    {
      # Matches firejail mpv.profile + Flathub io.mpv.Mpv (no SessionManager:
      # ScreenSaver covers idle inhibit without Logout/Shutdown).
      dbus.policies = {
        "org.mpris.MediaPlayer2.mpv" = "own";
        "org.freedesktop.ScreenSaver" = "talk"; # inhibit idle during playback
        "org.freedesktop.portal.*" = "talk"; # file chooser
      };
      bubblewrap.bind = {
        rw = [
          # Watch-later state (~/.config/mpv is already bound rw by utils.nix)
          (sloth.mkdir (sloth.concat' sloth.homeDir "/.local/state/mpv"))
        ];
        # Media folders (read-only)
        ro = [
          (sloth.concat' sloth.homeDir "/Videos")
          (sloth.concat' sloth.homeDir "/Music")
          (sloth.concat' sloth.homeDir "/Downloads")
        ];
      };
    };
}
