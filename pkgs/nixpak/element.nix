{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
  # Links: Element shells out to xdg-open; this one goes via the portal.
  sandboxedXdgUtils = pkgs.callPackage ../../nixpak/xdg-utils.nix { };
in
utils.mkSandboxed {
  # Plaintext safeStorage: Chromium's encrypted mode needs the Secret Service
  # itself, and the D-Bus proxy can't scope that to Element's own item, so it
  # would expose the whole login keyring. The key in ~/.config/Element is
  # protected at rest by LUKS.
  package = pkgs.element-desktop.override {
    commandLineArgs = "--storage-mode=force-plaintext";
  };
  configDir = "Element";
  extraPackages = [ sandboxedXdgUtils ];
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
      # Matches Flathub's im.riot.Riot. No org.freedesktop.secrets (see above).
      dbus.policies = {
        "org.freedesktop.Notifications" = "talk";
        # Secret, file chooser, OpenURI (links -> host browser), screencast
        "org.freedesktop.portal.*" = "talk";
        "org.kde.StatusNotifierWatcher" = "talk"; # tray icon
        "org.freedesktop.ScreenSaver" = "talk"; # inhibit idle during calls
        "com.canonical.Unity" = "talk"; # unread badge (dash-to-dock)
      };
      bubblewrap.bind.rw = [
        (sloth.concat' sloth.homeDir "/Downloads")
      ];
    };
}
