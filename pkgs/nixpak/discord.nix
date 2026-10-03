{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
  # Links: Discord execs xdg-open; this one goes via the portal.
  sandboxedXdgUtils = pkgs.callPackage ../../nixpak/xdg-utils.nix { };
in
utils.mkSandboxed {
  # --password-store=basic: as for Element/Signal, encrypted safeStorage
  # needs the whole login keyring (org.freedesktop.secrets).
  package = pkgs.discord.override {
    commandLineArgs = "--password-store=basic";
  };
  name = "discord";
  configDir = "discord";
  displayName = "Discord";
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
      # Flathub's com.discordapp.Discord minus the legacy Unity/AppMenu
      # names. Not carried over from it: --device=all (camera; Discord's own
      # voice engine opens /dev/video* directly, and a launch-time device
      # bind misses later hotplugs anyway), pcsc, and the discord-ipc-0
      # socket bridge (Rich Presence for games running on the host).
      dbus.policies = {
        "org.freedesktop.Notifications" = "talk";
        # File chooser, OpenURI (links -> host browser), screencast
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
