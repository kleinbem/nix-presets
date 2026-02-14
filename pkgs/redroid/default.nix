{ pkgs, inputs }:
let
  system = pkgs.system;

  # Define Docker Image Sources (Managed by update.sh)
  redroidHashes = {
    aarch64-linux = {
      imageDigest = "sha256:0000000000000000000000000000000000000000000000000000000000000000"; # REPLACE_DIGEST_ARM64
      sha256 = "0000000000000000000000000000000000000000000000000000"; # REPLACE_SHA256_ARM64
    };
    x86_64-linux = {
      imageDigest = "sha256:0000000000000000000000000000000000000000000000000000000000000000"; # REPLACE_DIGEST_AMD64
      sha256 = "0000000000000000000000000000000000000000000000000000"; # REPLACE_SHA256_AMD64
    };
  };

  redroidSource = redroidHashes.${system};

  # Select GApps source
  gappsSrc = if system == "aarch64-linux" then inputs.gapps-arm64 else inputs.gapps-amd64; # Tries BiTGApps (which is placeholder now)

  gappsLayer = pkgs.runCommand "extract-gapps" { buildInputs = [ pkgs.unzip ]; } ''
    mkdir -p $out
    # Check if the source is a real file (not placeholder) before unzipping
    if [ -s "${gappsSrc}" ] && [[ "${gappsSrc}" == *.zip ]]; then
      unzip ${gappsSrc} -d temp
      cp -r temp/system $out/
    else
      echo "Warning: GApps source for ${system} is invalid or placeholder. Skipping GApps injection."
      mkdir -p $out/system
      # Create a dummy file to ensure the layer isn't empty if that causes issues, 
      # or just leave it empty.
      echo "No GApps installed" > $out/system/gapps-missing.txt
    fi
  '';

  github_user = "kleinbem";

in
{
  redroid-gapps = pkgs.dockerTools.buildLayeredImage {
    name = "ghcr.io/${github_user}/redroid-gapps";
    tag = "16.0.0";
    fromImage = pkgs.dockerTools.pullImage {
      imageName = "redroid/redroid";
      imageDigest = redroidSource.imageDigest;
      sha256 = redroidSource.sha256;
      finalImageName = "redroid/redroid";
      finalImageTag = "16.0.0_64only-latest";
    };
    contents = [ gappsLayer ];
    config = {
      Cmd = [
        "/init"
        "androidboot.hardware=redroid"
        "ro.setupwizard.mode=DISABLED"
      ];
    };
  };
}
