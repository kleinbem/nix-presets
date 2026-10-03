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
  discord = call ./discord.nix;
  element-desktop = call ./element.nix;
  github-desktop = call ./github-desktop.nix;
  lmstudio = call ./lmstudio.nix;
  mpv = call ./mpv.nix;
  obsidian = call ./obsidian.nix;
  signal-desktop = call ./signal.nix;
  slack = call ./slack.nix;
}
