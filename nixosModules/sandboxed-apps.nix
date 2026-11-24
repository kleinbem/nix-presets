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
    inherit (cfg) extraBindRw;
  };
  appType = lib.types.enum (builtins.attrNames sandboxed);
in
{
  options.my.desktop.sandboxedApps = {
    enable = lib.mkEnableOption "nixpak-sandboxed desktop apps";
    apps = lib.mkOption {
      type = lib.types.listOf appType;
      # bitwarden stays out of the default list: its polkit policy (biometric
      # unlock) and desktop_proxy bridge must land in the system profile.
      # zotero is opt-in via extraApps: it depends on firefox-esr-140-bin-unwrapped,
      # which requires an explicit allowInsecurePredicate on the consuming host.
      default = [
        "chromium"
        "discord"
        "element-desktop"
        "github-desktop"
        "ladybird"
        "lmstudio"
        "mpv"
        "obs-studio"
        "obsidian"
        "signal-desktop"
        "slack"
        "zathura"
      ];
      description = "Which sandboxed apps from pkgs/nixpak/ to install.";
    };
    extraApps = lib.mkOption {
      type = lib.types.listOf appType;
      default = [ ];
      description = "Additional sandboxed apps to install alongside `apps` (e.g. `zotero` on hosts that allowlist its runtime).";
    };
    extraBindRw = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      description = "Host-specific read-write bind paths keyed by app name (e.g. `lmstudio = [ \"/var/lib/images/lmstudio\" ]`).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = map (name: sandboxed.${name}) (lib.unique (cfg.apps ++ cfg.extraApps));
  };
}
