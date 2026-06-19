{ config, lib, pkgs, inputs, ... }:

let
  cfg = config.my.desktop.claude;
  
  # Fetch the packages directly from the flakes
  claude-heytcass = inputs.claude-for-linux.packages.${pkgs.system}.claude-desktop;
  claude-cowork = inputs.claude-cowork-nix.packages.${pkgs.system}.claude-desktop;

  # Create a wrapper for cowork so they don't collide
  claude-cowork-wrapped = pkgs.symlinkJoin {
    name = "claude-desktop-cowork";
    paths = [ claude-cowork ];
    postBuild = ''
      # Rename the binary
      mv $out/bin/claude-desktop $out/bin/claude-desktop-cowork
      
      # If there is a desktop file, rename it and update its Exec line
      if [ -d $out/share/applications ]; then
        mv $out/share/applications/claude-desktop.desktop $out/share/applications/claude-desktop-cowork.desktop || true
        sed -i 's/Exec=claude-desktop/Exec=claude-desktop-cowork/g' $out/share/applications/claude-desktop-cowork.desktop || true
        sed -i 's/Name=Claude/Name=Claude (Cowork)/g' $out/share/applications/claude-desktop-cowork.desktop || true
      fi
    '';
  };

in {
  options.my.desktop.claude = {
    enable = lib.mkEnableOption "Community Claude Desktop Apps (heytcass and cowork)";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      claude-heytcass
      claude-cowork-wrapped
    ];
  };
}
