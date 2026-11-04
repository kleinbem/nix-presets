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

          # 1. Bypass coldStart eviction check in Google OAuth callback (matches across variable name rotations)
          sed -i -E 's/!\(([a-zA-Z0-9_$]+)!=null&&!i&&([a-zA-Z0-9_$]+)\(\1\.getURL\(\)\)\)/!(\1!=null\&\&\2(\1.getURL()))/g' "$mainChunk"

          # 2. Allow root and empty pathname in subscriber surface set alongside /login and /gift/redeem
          substituteInPlace "$mainChunk" \
            --replace-fail 'new Set(["/login","/gift/redeem"])' 'new Set(["/login","/gift/redeem","/",""])'

          # 3. Patch race-prone WeakSet check in EU() if present in this upstream version
          substituteInPlace "$mainChunk" \
            --replace-quiet 'function EU(e){let t=e.webContents;return!t||t.isDestroyed()||!ufr.has(t)}' 'function EU(e){let t=e.webContents;return!t||t.isDestroyed()}' || true
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
