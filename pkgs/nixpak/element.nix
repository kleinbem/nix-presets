{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
  # Links: Element shells out to xdg-open; this one goes via the portal.
  sandboxedXdgUtils = pkgs.callPackage ../../nixpak/xdg-utils.nix { };
in
utils.mkSandboxed {
  # safeStorage: Chromium only does "encrypted" by talking to the Secret
  # Service directly — the Secret portal / keyring control socket (what
  # Flathub grants) aren't enough — and the proxy can't scope that to
  # Element's own item (GetSecrets takes any item path), so granting it
  # hands a compromised Element the whole login keyring (GOA tokens etc.).
  # Plaintext instead, pinned so it's explicit rather than a fallback:
  # the key sits in ~/.config/Element, protected at rest by LUKS, and
  # readable at runtime only by what can already query the unlocked
  # keyring anyway (any unsandboxed process as this user).
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
      # Matches Flathub's im.riot.Riot. Deliberately NOT
      # org.freedesktop.secrets, which firejail's profile allows (see above).
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
