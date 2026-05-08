{ pkgs, ... }:

{
  # Bluefin DX inspired Developer Experience (Nixified)
  # This module replicates the 'devmode' of Bluefin/Aurora without using Flatpaks.
  # It provides a suite of GUI and CLI tools, along with the full Nerd Font collection.

  home.packages = with pkgs; [
    # --- GUI Developer Tools (Bluefin Style) ---
    pods # Native GNOME Podman Manager
    boxbuddy # Native GUI for Distrobox

    # --- CLI Developer Tools ---
    distrobox # Core of the atomic/cloud-native workflow
    just # The engine for 'os' commands
    gh # GitHub CLI
    lazygit # TUI for Git
    lazydocker # TUI for Podman/Docker
    tldr # Modern, simplified man pages
    dmidecode # For 'just bios-info'

    # --- Bluefin DX Font Suite (Nerd Fonts) ---
    # Replicating the exact list from 'ujust devmode'
    nerd-fonts.caskaydia-mono
    nerd-fonts.comic-shanns-mono
    nerd-fonts.droid-sans-mono
    nerd-fonts.go-mono
    nerd-fonts.blex-mono # IBM Plex Mono
    nerd-fonts.sauce-code-pro
    source-code-pro
    nerd-fonts.ubuntu
    nerd-fonts.fira-code
    nerd-fonts._0xproto # 0xProto
    nerd-fonts.jetbrains-mono
  ];

  # --- Distrobox Integration ---
  # Ensuring Ptyxis and other tools can see Distrobox containers.
  # Ptyxis is already container-aware and will detect these automatically.
}
