{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
in
utils.mkSandboxed {
  # --password-store=basic: avoid exposing the whole login keyring.
  # WebRtcPipeWireCamera: webcam via portal rather than fixed /dev/video* binds.
  package = pkgs.chromium.override {
    commandLineArgs = "--password-store=basic --enable-features=WebRtcPipeWireCamera";
  };
  name = "chromium";
  configDir = "chromium";
  displayName = "Chromium";
  presets = [
    "wayland"
    "gpu"
    "audio"
    "network"
  ];
  extraPerms =
    { sloth, ... }:
    {
      # Flathub's org.chromium.Chromium minus org.freedesktop.secrets and
      # org.gnome.SessionManager.
      dbus.policies = {
        "org.freedesktop.Notifications" = "talk";
        # File chooser, Camera, ScreenCast, OpenURI
        "org.freedesktop.portal.*" = "talk";
        "org.freedesktop.ScreenSaver" = "talk";
        "org.kde.StatusNotifierWatcher" = "talk";
        "org.mpris.MediaPlayer2.chromium.*" = "own";
      };
      bubblewrap.bind = {
        rw = [
          (sloth.concat' sloth.homeDir "/Downloads")
          # Local CUPS socket for printing (mirrors firejail --noblacklist=/etc/cups)
          "/run/cups"
        ];
        ro = [
          "/etc/cups"
        ];
      };
    };
}
