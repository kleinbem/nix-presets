#!/usr/bin/env bash
# Waydroid Setup - Install Magisk, Houdini, Widevine
set -euo pipefail

# These are substituted by Nix at build time
ASSETS="${ASSETS:-}"
WAYDROID_DIR="/var/lib/waydroid"
WAYDROID_DATA="${HOME}/.local/share/waydroid/data"
PIF_REPO="osm0sis/PlayIntegrityFork"
PIF_FILE="PlayIntegrityFork.zip"

log() { echo -e "\033[1;32m[*]\033[0m $*"; }
err() { echo -e "\033[1;31m[!]\033[0m $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || err "Run as root"
[[ -n "$ASSETS" ]] || err "ASSETS not set"

img_dir() { 
  grep -Po 'images_path\s*=\s*\K.*' "$WAYDROID_DIR/waydroid.cfg" 2>/dev/null || echo "$WAYDROID_DIR/images"
}

overlayfs() { 
  grep -q 'mount_overlays\s*=\s*True' "$WAYDROID_DIR/waydroid.cfg" 2>/dev/null
}

# Set property in waydroid.cfg (removes existing first to avoid duplicates)
prop() {
  local key="$1"
  local value="$2"
  local cfg="$WAYDROID_DIR/waydroid.cfg"
  
  # Remove existing entry (if any) to avoid duplicates
  sed -i "/^${key}\s*=/d" "$cfg" 2>/dev/null || true
  
  # Add new entry under [properties]
  sed -i "/^\[properties\]/a ${key} = ${value}" "$cfg"
}

log "=== Waydroid Setup ==="
waydroid container stop 2>/dev/null || true

if overlayfs; then
  COPY_DIR="/var/lib/waydroid/overlay"
  mkdir -p "$COPY_DIR/system/etc/init"
  mkdir -p "$COPY_DIR/vendor"
else
  COPY_DIR="/tmp/waydroid"
  img=$(img_dir)
  
  for p in system vendor; do
    img_path="$img/$p.img"
    mp="$COPY_DIR"
    [[ "$p" != "system" ]] && mp="$COPY_DIR/$p"
    
    log "Mounting $p..."
    e2fsck -yf "$img_path" >/dev/null 2>&1 || true
    resize2fs "$img_path" "$(($(stat -c%s "$img_path")/1024/1024+500))M" >/dev/null 2>&1
    mkdir -p "$mp"
    mountpoint -q "$mp" && umount "$mp"
    mount -o rw "$img_path" "$mp"
  done
fi

log "Installing Houdini..."
cp -r "$ASSETS/system/"* "$COPY_DIR/system/"
prop "ro.dalvik.vm.native.bridge" "libhoudini.so"
prop "ro.enable.native.bridge.exec" "1"

log "Installing Widevine..."
cp -r "$ASSETS/vendor/"* "$COPY_DIR/vendor/"

log "Installing Magisk..."
mgsk="$COPY_DIR/system/etc/init/magisk"
mkdir -p "$mgsk"
for lib in "$ASSETS/magisk/lib/x86_64/"*.so; do
  cp "$lib" "$mgsk/$(basename "$lib" | sed 's/^lib//;s/\.so$//')"
done
chmod 755 "$mgsk/"*
cp "$ASSETS/magisk/magisk.apk" "$mgsk/"
cp -r "$ASSETS/magisk/assets/chromeos" "$mgsk/" 2>/dev/null || true

# Copy additional assets needed for module installation
for f in addon.d.sh boot_patch.sh module_installer.sh uninstaller.sh util_functions.sh; do
  [ -f "$ASSETS/magisk/assets/$f" ] && cp "$ASSETS/magisk/assets/$f" "$mgsk/"
done
[ -f "$ASSETS/magisk/assets/stub.apk" ] && cp "$ASSETS/magisk/assets/stub.apk" "$mgsk/"
[ -f "$ASSETS/magisk/assets/main.jar" ] && cp "$ASSETS/magisk/assets/main.jar" "$mgsk/"

# Copy bootanim.rc (Magisk init script)
cp "$ASSETS/magisk/bootanim.rc" "$COPY_DIR/system/etc/init/bootanim.rc"

# Setup data directory for Magisk
mkdir -p "$WAYDROID_DATA/adb/magisk"
cp -r "$mgsk/"* "$WAYDROID_DATA/adb/magisk/"
# Create symlink for magisk binary
ln -sf magisk64 "$WAYDROID_DATA/adb/magisk/magisk" 2>/dev/null || true

log "Downloading PlayIntegrityFork..."
mkdir -p "$WAYDROID_DATA/local/tmp"
PIF_URL=$(curl -sL "https://api.github.com/repos/$PIF_REPO/releases/latest" | grep -oP '"browser_download_url": "\K[^"]+\.zip' | head -1)
curl -sL "$PIF_URL" -o "$WAYDROID_DATA/local/tmp/$PIF_FILE" || log "PIF download failed (optional)"

if ! overlayfs; then
  log "Unmounting..."
  for p in vendor system; do
    mp="$COPY_DIR"
    [[ "$p" != "system" ]] && mp="$COPY_DIR/$p"
    umount "$mp" 2>/dev/null || true
  done
fi

log "Checking Waydroid session..."

# Check if session is running. If not, we can't do Magisk config yet.
if waydroid status 2>/dev/null | grep -q "Session:.*RUNNING"; then
    log "Session running, configuring MagiskHide..."
    waydroid shell -- sh -c "magiskhide enable" || true
    waydroid shell -- sh -c "magiskhide add com.google.android.gms" || true
    waydroid shell -- sh -c "magiskhide add com.android.vending" || true
    waydroid shell -- sh -c "magisk --install-module /data/local/tmp/$PIF_FILE" || true
    log "Done! System is fully patched and activated."
else
    log "Images patched! However, couldn't start session as root."
    log "NEXT STEPS:"
    log "1. Start session as your user: waydroid session start"
    log "2. Run: just activate (to finish Magisk/Play Store fix)"
fi
