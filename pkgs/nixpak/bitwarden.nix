# Draft only — NOT in sandboxed-apps.nix's default list. Bitwarden stays a
# plain system package in nix-config/modules/nixos/desktop.nix so its polkit
# policy (biometric unlock) and desktop_proxy bridge (Chrome extension link)
# land in the system profile.
{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
  sandboxedXdgUtils = pkgs.callPackage ../../nixpak/xdg-utils.nix { };
in
utils.mkSandboxed {
  package = pkgs.bitwarden-desktop;
  name = "bitwarden";
  configDir = "Bitwarden";
  displayName = "Bitwarden";
  extraPackages = [ sandboxedXdgUtils ];
  presets = [
    "wayland"
    "gpu"
    "network"
    "usb"
    "u2f"
  ];
  extraPerms = _: {
    dbus.policies = {
      "org.freedesktop.Notifications" = "talk";
      "org.freedesktop.portal.*" = "talk";
      "org.kde.StatusNotifierWatcher" = "talk";
    };
  };
}
