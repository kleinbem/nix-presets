{
  pkgs,
  nixpak,
}:

let
  call =
    file:
    import file {
      inherit pkgs nixpak;
      inherit (pkgs) lib;
    };
in
{
  bitwarden = call ./bitwarden.nix;
  chromium = call ./chromium.nix;
  discord = call ./discord.nix;
  element-desktop = call ./element.nix;
  github-desktop = call ./github-desktop.nix;
  ladybird = call ./ladybird.nix;
  lmstudio = call ./lmstudio.nix;
  mpv = call ./mpv.nix;
  obs-studio = call ./obs-studio.nix;
  obsidian = call ./obsidian.nix;
  signal-desktop = call ./signal.nix;
  slack = call ./slack.nix;
  zathura = call ./zathura.nix;
  zotero = call ./zotero.nix;
}
