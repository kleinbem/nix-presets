{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
  sandboxedXdgUtils = pkgs.callPackage ../../nixpak/xdg-utils.nix { };
in
utils.mkSandboxed {
  package = pkgs.stable.discord;
  name = "discord";
  configDir = "discord";
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
            # Downloads for saving files
            (sloth.concat' sloth.homeDir "/Downloads")
          ];
        };
        env = {
          # Open links on host
          DBUS_SESSION_BUS_ADDRESS = sloth.env "DBUS_SESSION_BUS_ADDRESS";
          BROWSER = "xdg-open";
          NIXOS_OZONE_WL = "1";
        };
      };
    };
}
