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
    inputs.claude-for-linux.packages.${pkgs.stdenv.hostPlatform.system}.claude-desktop.overrideAttrs
      (oldAttrs: {
        nativeBuildInputs = (oldAttrs.nativeBuildInputs or [ ]) ++ [ pkgs.asar ];
        postInstall = (oldAttrs.postInstall or "") + ''
          # Patch Google OAuth deep-link callback handling in app.asar to prevent silent eviction on Linux second-instance handoff
          # Upstream fix tracked in NixOS/nixpkgs#537215 / minegameYTB/nixpkgs#2
          asar extract "$out/lib/claude-desktop/resources/app.asar" asar-unpacked
          mainChunk=$(grep -l "desktop_login_callback_evicted" asar-unpacked/.vite/build/index.chunk-*.js)
          substituteInPlace "$mainChunk" \
            --replace-fail "!(r!=null&&!i&&gfr(r.getURL()))" "!(r!=null&&gfr(r.getURL()))" \
            --replace-fail 'var hfr=new Set(["/login","/gift/redeem"]);' 'var hfr=new Set(["/login","/gift/redeem","/",""]);' \
            --replace-fail 'function EU(e){let t=e.webContents;return!t||t.isDestroyed()||!ufr.has(t)}' 'function EU(e){let t=e.webContents;return!t||t.isDestroyed()}'
          rm -rf asar-unpacked/compile-cache
          asar pack asar-unpacked "$out/lib/claude-desktop/resources/app.asar"
          rm -rf asar-unpacked
        '';
      });
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
