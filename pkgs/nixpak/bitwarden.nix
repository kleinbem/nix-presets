{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
in
utils.mkSandboxed {
  package = pkgs.stable.bitwarden-desktop;
  name = "bitwarden";
  configDir = "Bitwarden";
  extraPackages = [ pkgs.xdg-utils ];
  presets = [
    "wayland"
    "gpu"
    "network"
    "dbus"
    "usb"
    "u2f"
  ];
  extraPerms = _: {
    bubblewrap.bind = {
      rw = [
        # No extra file access needed, just the config dir which utils handles
      ];
    };
  };
}
