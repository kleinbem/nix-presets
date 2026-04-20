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
          # Restrict D-Bus to prevent context escape
          # Only BROWSER/xdg-open should be able to communicate back to host
          NIXOS_OZONE_WL = "1";
          BROWSER = "xdg-open";
        };
      };
    };
}
