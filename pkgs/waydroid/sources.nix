# Sources for Waydroid setup
# Assets fetched at build time (cached, reproducible)
{ pkgs }:

{
  # Libhoudini - ARM translation for x86_64 (Android 11)
  houdini = pkgs.fetchzip {
    url = "https://github.com/supremegamers/vendor_intel_proprietary_houdini/archive/81f2a51ef539a35aead396ab7fce2adf89f46e88.zip";
    hash = "sha256-I6G0aaHFIMSOeh1rtlTfjbwSNX1wpSXhNSVcbBrNNQs=";
  };

  # Widevine DRM L3 (Android 11 x86_64)
  widevine = pkgs.fetchzip {
    url = "https://github.com/supremegamers/vendor_google_proprietary_widevine-prebuilt/archive/48d1076a570837be6cdce8252d5d143363e37cc1.zip";
    hash = "sha256-ry+LKhhYPcqPliqPSWkFABmulGMeWbLdQlEa9acoEj8=";
  };

  # Kitsune Mask (formerly Magisk Delta) - Official latest release
  magisk = pkgs.fetchurl {
    url = "https://github.com/1q23lyc45/KitsuneMagisk/releases/download/v27.2-kitsune-4/app-release.apk";
    sha256 = "129sjs8cy4dsaz31grb69cbfbhwyqgxm0d4mrirybnixg01gm341";
  };

  # Waydroid Images (Lineage 20.0 GAPPS)
  # Downloaded via Nix for speed and reliability
  system_img = pkgs.fetchurl {
    url = "https://downloads.sourceforge.net/project/waydroid/images/system/lineage/waydroid_x86_64/lineage-20.0-20250809-GAPPS-waydroid_x86_64-system.zip";
    sha256 = "0kkc3zjnsz8rfk6515cqqfcir6a9plwk6mfxflblx95gd9zgjphc";
  };

  vendor_img = pkgs.fetchurl {
    url = "https://downloads.sourceforge.net/project/waydroid/images/vendor/waydroid_x86_64/lineage-20.0-20250809-MAINLINE-waydroid_x86_64-vendor.zip";
    sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; # Update this later with nix run .#update-hashes
  };
}
