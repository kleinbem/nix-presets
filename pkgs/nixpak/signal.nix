{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
  sandboxedXdgUtils = pkgs.callPackage ../../nixpak/xdg-utils.nix { };
in
utils.mkSandboxed {
  package = pkgs.stable.signal-desktop;
  name = "signal-desktop";
  configDir = "Signal";
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
      bubblewrap = {
        bind = {
          rw = [
            # Downloads
            (sloth.concat' sloth.homeDir "/Downloads")
          ];
        };
        env = {
          DBUS_SESSION_BUS_ADDRESS = sloth.env "DBUS_SESSION_BUS_ADDRESS";
          BROWSER = "xdg-open";
          NIXOS_OZONE_WL = "1";
        };
      };
    };
}
