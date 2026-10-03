{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
in
utils.mkSandboxed {
  package = pkgs.element-desktop;
  configDir = "Element";
  displayName = "Element";
  presets = [
    "wayland"
    "gpu"
    "audio"
    "network"
  ];
  extraPerms =
    { sloth, ... }:
    {
      dbus.policies = {
        # safeStorage: Element encrypts its Matrix session keys with a
        # secret held in GNOME Keyring; without this it refuses to start.
        "org.freedesktop.secrets" = "talk";
        "org.freedesktop.Notifications" = "talk";
        # File chooser, OpenURI (links open in the host browser), screencast
        "org.freedesktop.portal.*" = "talk";
        "org.kde.StatusNotifierWatcher" = "talk";
      };
      bubblewrap.bind.rw = [
        (sloth.concat' sloth.homeDir "/Downloads")
      ];
    };
}
