{
  pkgs,
  nixpak,
  homeDirectory ? "/home/martin",
}:

let
  call =
    file:
    import file {
      inherit pkgs nixpak;
      inherit (pkgs) lib;
    };
  chrome = import ./chrome.nix {
    inherit pkgs nixpak homeDirectory;
    inherit (pkgs) lib;
  };
in
{
  bitwarden = call ./bitwarden.nix;
  discord = call ./discord.nix;
  github-desktop = call ./github-desktop.nix;
  lmstudio = call ./lmstudio.nix;
  mpv = call ./mpv.nix;
  obsidian = call ./obsidian.nix;
  signal-desktop = call ./signal.nix;
  slack = call ./slack.nix;

  # Chrome Variants
  google-chrome-stable = chrome.stable;
  google-chrome-stable-vault = chrome.vault;
  google-chrome-stable-hazard = chrome.hazard;
}
