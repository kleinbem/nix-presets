{
  pkgs,
  nixpak,
  extraBindRw ? { },
  ...
}:
import ../pkgs/nixpak/default.nix { inherit pkgs nixpak extraBindRw; }
