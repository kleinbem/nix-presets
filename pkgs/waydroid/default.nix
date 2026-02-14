{ pkgs }:

let
  sources = import ./sources.nix { inherit pkgs; };

  # Pre-built assets derivation
  assets = pkgs.stdenv.mkDerivation {
    name = "waydroid-assets";
    dontUnpack = true;
    dontBuild = true;
    dontConfigure = true;

    installPhase = ''
      mkdir -p $out/{system/etc/init,vendor,magisk}

      # Houdini (ARM translation)
      cp -rL ${sources.houdini}/prebuilts/* $out/system/
      chmod -R u+w $out/system/
      cp ${./assets/houdini.rc} $out/system/etc/init/houdini.rc

      # Widevine (DRM)
      cp -rL ${sources.widevine}/prebuilts/* $out/vendor/

      # Magisk Delta
      ${pkgs.unzip}/bin/unzip -q ${sources.magisk} -d $out/magisk
      cp ${sources.magisk} $out/magisk/magisk.apk
      cp ${./assets/bootanim.rc} $out/magisk/bootanim.rc
    '';
  };

  # Runtime deps for scripts
  runtimeDeps = with pkgs; [
    coreutils
    util-linux
    e2fsprogs
    gnused
    gnugrep
    curl
    sqlite
  ];

  # Main install script with ASSETS substituted
  installScript = pkgs.writeShellApplication {
    name = "waydroid-setup";
    runtimeInputs = runtimeDeps;
    text = builtins.replaceStrings [ ''ASSETS="''${ASSETS:-}"'' ] [ ''ASSETS="${assets}"'' ] (
      builtins.readFile ./scripts/install.sh
    );
  };

  # Simple script wrappers
  getIdScript = pkgs.writeShellApplication {
    name = "waydroid-get-id";
    runtimeInputs = runtimeDeps;
    text = builtins.readFile ./scripts/get-id.sh;
  };

  statusScript = pkgs.writeShellApplication {
    name = "waydroid-status";
    runtimeInputs = runtimeDeps;
    text = builtins.readFile ./scripts/status.sh;
  };

  uninstallScript = pkgs.writeShellApplication {
    name = "waydroid-uninstall";
    runtimeInputs = runtimeDeps;
    text = builtins.readFile ./scripts/uninstall.sh;
  };

  updatePifScript = pkgs.writeShellApplication {
    name = "waydroid-update-pif";
    runtimeInputs = runtimeDeps;
    text = builtins.readFile ./scripts/update-pif.sh;
  };

  restartScript = pkgs.writeShellApplication {
    name = "waydroid-restart";
    runtimeInputs = runtimeDeps;
    text = builtins.readFile ./scripts/restart.sh;
  };

  activateScript = pkgs.writeShellApplication {
    name = "waydroid-activate";
    runtimeInputs = runtimeDeps;
    text = builtins.readFile ./scripts/activate.sh;
  };

  checkScript = pkgs.writeShellApplication {
    name = "waydroid-check";
    runtimeInputs = runtimeDeps;
    text = builtins.readFile ./scripts/check.sh;
  };

  updateHashesScript = pkgs.writeShellScriptBin "waydroid-update-hashes" ''
    ${pkgs.nix}/bin/nix-prefetch-url "https://downloads.sourceforge.net/project/waydroid/images/vendor/waydroid_x86_64/lineage-20.0-20250809-MAINLINE-waydroid_x86_64-vendor.zip"
  '';

  # Waydroid Images package
  images = pkgs.stdenv.mkDerivation {
    name = "waydroid-images";
    nativeBuildInputs = [ pkgs.unzip ];
    dontUnpack = true;
    installPhase = ''
      mkdir -p $out
      unzip -p ${sources.system_img} system.img > $out/system.img
      unzip -p ${sources.vendor_img} vendor.img > $out/vendor.img
    '';
  };
in
{
  default = installScript;
  install = installScript;
  get-id = getIdScript;
  status = statusScript;
  uninstall = uninstallScript;
  update-pif = updatePifScript;
  restart = restartScript;
  activate = activateScript;
  check = checkScript;
  update-hashes = updateHashesScript;
  inherit assets images;
}
