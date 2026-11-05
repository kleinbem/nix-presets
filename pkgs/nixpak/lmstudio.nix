{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
in
utils.mkSandboxed {
  package = pkgs.lmstudio;
  name = "lmstudio";
  presets = [
    "wayland"
    "gpu"
    "audio"
    "network"
  ];
  extraPerms = _: {
    bubblewrap.bind = {
      rw = [
        # Model storage
        "/images/lmstudio"
      ];
    };
  };
}
