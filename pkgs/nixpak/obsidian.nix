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
        (sloth.concat' sloth.homeDir "/GoogleDrive/Obsidian/MyVault")
      ];
      bubblewrap.bind.ro = [
        # Link system documentation into the vault sandbox
        (sloth.concat' sloth.homeDir "/Develop/github.com/kleinbem/nix/docs")
      ];
    };
}
