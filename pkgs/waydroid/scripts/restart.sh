#!/usr/bin/env bash
# Restart Waydroid container and session
set -euo pipefail

log() { echo -e "\033[1;32m[*]\033[0m $*"; }

log "Stopping Waydroid container..."
sudo waydroid container stop 2>/dev/null || true

log "Starting Waydroid container..."
sudo waydroid container start &
sleep 2

log "Starting Waydroid session..."
waydroid session start &

log "Waydroid restarted!"
