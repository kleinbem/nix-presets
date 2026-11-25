{ pkgs, ... }:

let
  python = pkgs.python3.withPackages (
    ps: with ps; [
      requests
      authlib
      cryptography
    ]
  );
in
pkgs.writeShellApplication {
  name = "atlas";

  runtimeInputs = [
    python
    pkgs.nix
    pkgs.sops
    pkgs.systemd
    pkgs.colmena
    pkgs.netbird
    pkgs.btrfs-progs
  ];

  text = ''
    # The script is now co-located with this package in nix-presets
    PYTHON_SCRIPT="${./atlas.py}"

    exec python3 "$PYTHON_SCRIPT" "$@"
  '';
}
