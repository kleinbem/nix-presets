#!/usr/bin/env bash
# Update PlayIntegrityFix module to latest version
set -euo pipefail

log() { echo -e "\033[1;32m[*]\033[0m $*"; }
err() { echo -e "\033[1;31m[!]\033[0m $*" >&2; exit 1; }

PIF_URL="https://github.com/chiteroman/PlayIntegrityFix/releases/latest/download/PlayIntegrityFix.zip"
WAYDROID_DATA="${HOME}/.local/share/waydroid/data"
TARGET_ZIP="$WAYDROID_DATA/local/tmp/PlayIntegrityFix.zip"

log "Downloading latest PlayIntegrityFix..."
mkdir -p "$(dirname "$TARGET_ZIP")"
curl -sL "$PIF_URL" -o "$TARGET_ZIP" || err "Download failed"

log "Installing module into Waydroid..."
# Use waydroid shell to install via magisk CLI
waydroid shell su -c "magisk --install-module /data/local/tmp/PlayIntegrityFix.zip" || err "Installation failed"

log "PlayIntegrityFix updated! Please restart Waydroid."
