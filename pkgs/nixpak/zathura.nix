{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
in
utils.mkSandboxed {
  package = pkgs.zathura;
  name = "zathura";
  configDir = "zathura";
  displayName = "Zathura";
  # Offline document viewer: no network, no audio, no D-Bus (mirrors
  # firejail's zathura.profile: net none, nosound, dbus-user/system none).
  presets = [
    "wayland"
    "gpu"
  ];
  extraPerms =
    { sloth, ... }:
    {
      dbus.enable = false;
      # Nixpak defaults bubblewrap.network to true; disable it explicitly.
      bubblewrap = {
        network = false;
        bind.ro = [
          (sloth.concat' sloth.homeDir "/Documents")
          (sloth.concat' sloth.homeDir "/Downloads")
        ];
      };
    };
}
