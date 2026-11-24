{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
in
utils.mkSandboxed {
  package = pkgs.ladybird;
  name = "ladybird";
  executableName = "Ladybird";
  extraBinNames = [ "Ladybird" ];
  configDir = "Ladybird";
  displayName = "Ladybird";
  presets = [
    "wayland"
    "gpu"
    "audio"
    "network"
  ];
  extraPerms =
    { sloth, ... }:
    {
      dbus.policies = {
        "org.freedesktop.Notifications" = "talk";
        "org.freedesktop.portal.*" = "talk";
      };
      bubblewrap = {
        bind.rw = [
          (sloth.concat' sloth.homeDir "/Downloads")
        ];
        env.QT_QPA_PLATFORM = "wayland";
      };
    };
}
