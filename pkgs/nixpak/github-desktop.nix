{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
  # Links and OAuth login: GitHub Desktop execs xdg-open; route via portal.
  sandboxedXdgUtils = pkgs.callPackage ../../nixpak/xdg-utils.nix { };

  # github-desktop doesn't accept commandLineArgs in .override; wrap it so
  # Chromium safeStorage doesn't need the whole login keyring.
  githubDesktop = pkgs.symlinkJoin {
    inherit (pkgs.github-desktop) pname version meta;
    name = "github-desktop-${pkgs.github-desktop.version}";
    paths = [ pkgs.github-desktop ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/github-desktop \
        --add-flags "--password-store=basic"
    '';
  };
in
utils.mkSandboxed {
  package = githubDesktop;
  name = "github-desktop";
  configDir = "GitHub Desktop";
  displayName = "GitHub Desktop";
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
      dbus.policies = {
        "org.freedesktop.Notifications" = "talk";
        # File chooser (add local repo) and OpenURI (OAuth login, links)
        "org.freedesktop.portal.*" = "talk";
      };
      bubblewrap = {
        bind = {
          rw = [
            # Code repositories
            (sloth.concat' sloth.homeDir "/Develop")
            # SSH agent socket only (not all of $XDG_RUNTIME_DIR)
            (sloth.env "SSH_AUTH_SOCK")
          ];
          ro = [
            # Git & SSH config (read-only so the sandbox can't rewrite keys/hooks)
            (sloth.concat' sloth.homeDir "/.gitconfig")
            (sloth.concat' sloth.homeDir "/.config/git")
            (sloth.concat' sloth.homeDir "/.ssh")
          ];
        };
        env = {
          SSH_AUTH_SOCK = sloth.env "SSH_AUTH_SOCK";
          BROWSER = "xdg-open";
        };
      };
    };
}
