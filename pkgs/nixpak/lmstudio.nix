{
  pkgs,
  nixpak,
  extraBindRw ? [ ],
  ...
}:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
  sandboxedXdgUtils = pkgs.callPackage ../../nixpak/xdg-utils.nix { };
in
utils.mkSandboxed {
  # --password-store=basic: avoid exposing the whole login keyring.
  package = pkgs.lmstudio.override {
    commandLineArgs = "--password-store=basic";
  };
  name = "lmstudio";
  extraBinNames = [ "lm-studio" ];
  configDir = "LM Studio";
  displayName = "LM Studio";
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
      dbus.policies = {
        "org.freedesktop.Notifications" = "talk";
        "org.freedesktop.portal.*" = "talk";
        "org.kde.StatusNotifierWatcher" = "talk"; # tray icon
      };
      bubblewrap.bind.rw = [
        # LM Studio runtime, hub metadata, and default model dir
        (sloth.mkdir (sloth.concat' sloth.homeDir "/.lmstudio"))
      ]
      ++ extraBindRw;
    };
}
