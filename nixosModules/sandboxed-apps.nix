# nixpak (bubblewrap) sandboxed desktop apps, installed system-wide so every
# GNOME host gets them, including mac-mini, which lacks the home-manager
# desktop preset. Definitions: pkgs/nixpak/, shared base: nixpak/utils.nix.
{ inputs }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.my.desktop.sandboxedApps;
  sandboxed = import ../nixpak/apps.nix {
    inherit pkgs;
    inherit (inputs) nixpak;
  };
in
{
  options.my.desktop.sandboxedApps = {
    enable = lib.mkEnableOption "nixpak-sandboxed desktop apps";
    apps = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (builtins.attrNames sandboxed));
      # Only the ones reviewed against firejail/Flathub and tested live; the
      # other pkgs/nixpak/ drafts join as they're migrated.
      default = [
        "discord"
        "element-desktop"
        "signal-desktop"
      ];
      description = "Which sandboxed apps from pkgs/nixpak/ to install.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = map (name: sandboxed.${name}) cfg.apps;
  };
}
