{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

let
  cfg = config.my.desktop.claude;

  claude-heytcass =
    inputs.claude-for-linux.packages.${pkgs.stdenv.hostPlatform.system}.claude-desktop;
in
{
  options.my.desktop.claude = {
    enable = lib.mkEnableOption "Community Claude Desktop App (heytcass)";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      claude-heytcass
    ];
  };
}
