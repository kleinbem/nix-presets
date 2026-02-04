{ pkgs, nixpak }:

let
  call = file: import file { inherit pkgs nixpak; };
  chrome = call ./chrome.nix;
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
