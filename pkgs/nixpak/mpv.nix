{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
in
utils.mkSandboxed {
  package = pkgs.mpv;
  name = "mpv";
  presets = [
    "wayland"
    "gpu"
    "audio"
    "network"
  ];
  extraPerms =
    { sloth, ... }:
    {
      bubblewrap.bind = {
        rw = [
          (sloth.concat' sloth.homeDir "/.config/mpv")
        ];
        # Media Folders (Read-only for safety)
        ro = [
          (sloth.concat' sloth.homeDir "/Videos")
          (sloth.concat' sloth.homeDir "/Music")
          (sloth.concat' sloth.homeDir "/Downloads")
        ];
      };
    };
}
