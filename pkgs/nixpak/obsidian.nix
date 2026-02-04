{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
in
utils.mkSandboxed {
  package = pkgs.obsidian;
  presets = [
    "wayland"
    "gpu"
    "network"
  ];
  extraPerms =
    { sloth, ... }:
    {
      bubblewrap.bind.rw = [
        (sloth.concat' sloth.homeDir "/GoogleDrive/Obsidian")
      ];
    };
}
