{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
  # Links: Slack execs xdg-open; route via portal to host browser.
  sandboxedXdgUtils = pkgs.callPackage ../../nixpak/xdg-utils.nix { };

  # slack doesn't accept commandLineArgs in .override; wrap it like signal.nix:
  # - --password-store=basic: avoid exposing the whole login keyring.
  # - WebRtcPipeWireCamera: huddles camera via portal, not fixed /dev/video* binds.
  slack = pkgs.symlinkJoin {
    inherit (pkgs.slack) pname version meta;
    name = "slack-${pkgs.slack.version}";
    paths = [ pkgs.slack ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/slack \
        --add-flags "--password-store=basic --enable-features=WebRtcPipeWireCamera"
    '';
  };
in
utils.mkSandboxed {
  package = slack;
  name = "slack";
  configDir = "Slack";
  displayName = "Slack";
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
      # Matches Flathub's com.slack.Slack minus org.freedesktop.secrets and
      # org.gnome.SessionManager (ScreenSaver covers idle inhibit).
      dbus.policies = {
        "org.freedesktop.Notifications" = "talk";
        # File chooser, OpenURI (links -> host browser), Camera, ScreenCast
        "org.freedesktop.portal.*" = "talk";
        "org.kde.StatusNotifierWatcher" = "talk"; # tray icon
        "org.freedesktop.ScreenSaver" = "talk"; # inhibit idle during huddles
        "com.canonical.Unity" = "talk"; # unread badge (dash-to-dock)
      };
      bubblewrap = {
        bind.rw = [
          (sloth.concat' sloth.homeDir "/Downloads")
        ];
        env.BROWSER = "xdg-open";
      };
    };
}
