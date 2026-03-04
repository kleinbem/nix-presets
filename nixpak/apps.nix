{ pkgs, nixpak, homeDirectory ? "/home/martin", ... }: 
import ../pkgs/nixpak/default.nix { inherit pkgs nixpak homeDirectory; }
