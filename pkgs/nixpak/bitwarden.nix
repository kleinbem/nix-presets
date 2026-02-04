{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
in
utils.mkSandboxed {
  package = pkgs.stable.bitwarden-desktop;
  name = "bitwarden";
  configDir = "Bitwarden";
  presets = [
    "wayland"
    "gpu"
    "network"
  ];
  extraPerms = _: {
    bubblewrap.bind = {
      rw = [
        # No extra file access needed, just the config dir which utils handles
      ];
    };
  };
}
