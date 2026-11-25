{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
  # External links in notes exec xdg-open; route via portal to host browser.
  sandboxedXdgUtils = pkgs.callPackage ../../nixpak/xdg-utils.nix { };
in
utils.mkSandboxed {
  # --password-store=basic: encrypted safeStorage needs the whole login keyring
  # (org.freedesktop.secrets); disk is protected at rest by LUKS.
  package = pkgs.obsidian.override {
    commandLineArgs = "--password-store=basic";
  };
  name = "obsidian";
  configDir = "obsidian";
  displayName = "Obsidian";
  extraPackages = [ sandboxedXdgUtils ];
  presets = [
    "wayland"
    "gpu"
    "network"
  ];
  extraPerms =
    { sloth, ... }:
    {
      dbus.policies = {
        "org.freedesktop.Notifications" = "talk";
        # OpenURI (external links -> host browser) and FileChooser (attachments/export)
        "org.freedesktop.portal.*" = "talk";
      };
      bubblewrap.bind = {
        rw = [
          (sloth.concat' sloth.homeDir "/Documents/Notes")
        ];
        ro = [
          # System docs linked into the vault by notes-maintenance
          (sloth.concat' sloth.homeDir "/Develop/github.com/kleinbem/nix/docs")
        ];
      };
    };
}
