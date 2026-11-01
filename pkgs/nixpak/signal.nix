{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
  # Links: Signal execs xdg-open; this one goes via the portal.
  sandboxedXdgUtils = pkgs.callPackage ../../nixpak/xdg-utils.nix { };

  # nixpkgs' commandLineArgs is deprecated, so flags go on via a wrapper.
  # - --password-store=basic: encrypted storage would need the whole login
  #   keyring (org.freedesktop.secrets), so the key stays in ~/.config/Signal,
  #   protected at rest by LUKS.
  # - WebRtcPipeWireCamera: camera via the portal, not /dev/video* binds,
  #   which are fixed at launch and miss a webcam plugged in later.
  signal = pkgs.symlinkJoin {
    inherit (pkgs.signal-desktop) pname version meta;
    name = "signal-desktop-${pkgs.signal-desktop.version}";
    paths = [ pkgs.signal-desktop ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/signal-desktop \
        --add-flags "--password-store=basic --enable-features=WebRtcPipeWireCamera"
    '';
  };
in
utils.mkSandboxed {
  package = signal;
  configDir = "Signal";
  displayName = "Signal";
  extraPackages = [ sandboxedXdgUtils ];
  presets = [
    "wayland"
    "gpu"
    "audio"
    "network"
  ];
  # Electron's powerMonitor (Signal pauses on suspend and reconnects its
  # websocket on resume): a delay inhibitor + the PrepareFor* signals.
  # Nothing else on login1 — Flathub's blanket talk would include
  # PowerOff/Suspend, which polkit allows the active session without auth.
  systemDbusArgs = [
    "--call=org.freedesktop.login1=org.freedesktop.login1.Manager.Inhibit@/org/freedesktop/login1"
    "--broadcast=org.freedesktop.login1=org.freedesktop.login1.Manager.PrepareForSleep@/org/freedesktop/login1"
    "--broadcast=org.freedesktop.login1=org.freedesktop.login1.Manager.PrepareForShutdown@/org/freedesktop/login1"
  ];
  extraPerms =
    { sloth, ... }:
    {
      # Flathub's org.signal.Signal minus secrets/kwallet (see above) and
      # org.gnome.SessionManager (its Logout/Shutdown come along with
      # Inhibit); ScreenSaver covers idle inhibit.
      dbus.policies = {
        "org.freedesktop.Notifications" = "talk";
        # File chooser, OpenURI (links -> host browser), Camera, screencast
        "org.freedesktop.portal.*" = "talk";
        "org.kde.StatusNotifierWatcher" = "talk"; # tray icon
        "org.freedesktop.ScreenSaver" = "talk"; # inhibit idle during calls
        "com.canonical.Unity" = "talk"; # unread badge (dash-to-dock)
      };
      bubblewrap.bind.rw = [
        (sloth.concat' sloth.homeDir "/Downloads")
      ];
    };
}
