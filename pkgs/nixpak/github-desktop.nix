{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
  sandboxedXdgUtils = pkgs.callPackage ../../nixpak/xdg-utils.nix { };
in
utils.mkSandboxed {
  package = pkgs.github-desktop;
  name = "github-desktop";
  configDir = "GitHub Desktop";
  extraPackages = [
    sandboxedXdgUtils
    pkgs.git
    pkgs.openssh
  ];
  presets = [
    "wayland"
    "gpu"
    "network"
  ];
  extraPerms =
    { sloth, ... }:
    {
      bubblewrap = {
        bind = {
          rw = [
            # Code Repositories
            (sloth.concat' sloth.homeDir "/Develop")
          ];
          ro = [
            # Git & SSH Config
            (sloth.concat' sloth.homeDir "/.gitconfig")
            (sloth.concat' sloth.homeDir "/.ssh")
          ];
        };
        env = {
          # SSH Agent for YubiKey auth
          SSH_AUTH_SOCK = sloth.env "SSH_AUTH_SOCK";
          # Enable System Integration (Open Links/Apps) via DBus
          DBUS_SESSION_BUS_ADDRESS = sloth.env "DBUS_SESSION_BUS_ADDRESS";
          # Force invocation of our xdg-open wrapper
          BROWSER = "xdg-open";
        };
      };
    };
}
