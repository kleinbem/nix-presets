{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
  # External DOI/URL links exec xdg-open; route via portal to host browser.
  sandboxedXdgUtils = pkgs.callPackage ../../nixpak/xdg-utils.nix { };
in
utils.mkSandboxed {
  package = pkgs.zotero;
  name = "zotero";
  configDir = "zotero";
  displayName = "Zotero";
  extraPackages = [ sandboxedXdgUtils ];
  presets = [
    "wayland"
    "gpu"
    "network"
  ];
  extraPerms =
    { sloth, ... }:
    {
      # Browser Connector listens on 127.0.0.1:23119, which works with the
      # network preset (--share-net).
      dbus.policies = {
        "org.freedesktop.Notifications" = "talk";
        # FileChooser (PDF/BibTeX import) and OpenURI (links -> host browser)
        "org.freedesktop.portal.*" = "talk";
      };
      bubblewrap = {
        bind.rw = [
          # Gecko profile and Zotero library
          (sloth.mkdir (sloth.concat' sloth.homeDir "/.zotero"))
          (sloth.mkdir (sloth.concat' sloth.homeDir "/Zotero"))
          (sloth.concat' sloth.homeDir "/Downloads")
        ];
        env = {
          MOZ_ENABLE_WAYLAND = "1";
          BROWSER = "xdg-open";
        };
      };
    };
}
