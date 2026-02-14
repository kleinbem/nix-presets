#!/usr/bin/env bash
# Activate Magisk, MagiskHide, and Play Store fixes
# Updated with timeouts and verbose logging for debugging hangs
set -euo pipefail

PIF_FILE="PlayIntegrityFork.zip"

log() { echo -e "\033[1;32m[*]\033[0m $*"; }
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
err() { echo -e "\033[1;31m[!]\033[0m $*" >&2; exit 1; }

# Early sudo validation
sudo -v

# check if waydroid session is running
if ! waydroid status 2>/dev/null | grep -q "Session:.*RUNNING"; then
    err "Waydroid session is not running. Please run 'waydroid session start' first."
fi

# Ensure container is not frozen
if waydroid status 2>/dev/null | grep -q "Container:.*FROZEN"; then
    log "Container is FROZEN. Unfreezing now..."
    sudo waydroid container unfreeze || true
fi


# Wait for waydroidplatform service to be ready
log "Waiting for Waydroid platform service..."
for _i in {1..20}; do
    if waydroid prop get persist.waydroid.multi_windows >/dev/null 2>&1; then
        log "✓ Platform service ready"
        break
    fi
    echo -n "."
    sleep 2
done

log "Configuring Waydroid properties for Desktop Mode..."
# Standard desktop settings
waydroid prop set persist.waydroid.multi_windows true >/dev/null
waydroid prop set persist.waydroid.cursor_on_subsurface true >/dev/null
waydroid prop set persist.waydroid.fake_touch "" >/dev/null
waydroid prop set persist.waydroid.fake_wifi "on" >/dev/null
waydroid prop set persist.waydroid.width_padding 0 >/dev/null
waydroid prop set persist.waydroid.height_padding 0 >/dev/null


# =============================================================================
# MAGISK DELTA ACTIVATION
# =============================================================================

log "--- Magisk Activation (Verbose) ---"

# Step 1: Data environment
info "[Step 1] Preparing data/adb/magisk..."
timeout 30s sudo waydroid shell -- sh -c "mkdir -p /data/adb/magisk && chmod 755 /data/adb/magisk" || log "Warning: mkdir failed or timed out"
timeout 30s sudo waydroid shell -- sh -c "cp -r /system/etc/init/magisk/* /data/adb/magisk/ 2>/dev/null || true"
timeout 30s sudo waydroid shell -- sh -c "chmod 755 /data/adb/magisk/* 2>/dev/null || true"

# Step 2: sbin mount
info "[Step 2] Setting up sbin mount..."
timeout 30s sudo waydroid shell -- sh -c "mkdir -p /dev/magisk_waydroid" || true
# Try setup-sbin with a timeout to catch the hang
if timeout 30s sudo waydroid shell -- sh -c "/data/adb/magisk/magisk64 --auto-selinux --setup-sbin /data/adb/magisk /dev/magisk_waydroid 2>&1"; then
    info "✓ setup-sbin command completed"
else
    log "Warning: setup-sbin command timed out or failed (this is common if already setup)"
fi

# Step 3: Daemon
info "[Step 3] Starting Magisk daemon..."
timeout 30s sudo waydroid shell -- sh -c "/dev/magisk_waydroid/magisk --auto-selinux --daemon" || true
sleep 3

MAGISK_BIN="/dev/magisk_waydroid/magisk"
DAEMON_VERSION=$(timeout 10s sudo waydroid shell -- sh -c "$MAGISK_BIN -v 2>/dev/null" | tr -d '\r\n' || echo "UNKNOWN")

if [[ -n "$DAEMON_VERSION" ]] && [[ "$DAEMON_VERSION" != "UNKNOWN" ]]; then
    log "✓ Magisk Delta daemon running: $DAEMON_VERSION"
else
    info "Trying post-fs-data trigger..."
    timeout 30s sudo waydroid shell -- sh -c "$MAGISK_BIN --auto-selinux --post-fs-data" || true
    sleep 2
    DAEMON_VERSION=$(timeout 10s sudo waydroid shell -- sh -c "$MAGISK_BIN -v 2>/dev/null" | tr -d '\r\n' || echo "STILL_UNKNOWN")
    log "Current daemon version: $DAEMON_VERSION"
fi

# Step 4: Database Injection
log "--- Database Injection ---"
MAGISK_DB="/var/lib/waydroid/data/adb/magisk.db"
[ ! -f "$MAGISK_DB" ] && MAGISK_DB="$HOME/.local/share/waydroid/data/adb/magisk.db"

if [ -f "$MAGISK_DB" ]; then
    log "Forcing Zygisk in $MAGISK_DB..."
    sudo sqlite3 "$MAGISK_DB" "REPLACE INTO settings (key, value) VALUES ('zygisk', 1);" || true
    sudo sqlite3 "$MAGISK_DB" "REPLACE INTO settings (key, value) VALUES ('magiskhide', 1);" || true
else
    log "Warning: Magisk database not found on host. Attempting internal injection..."
    timeout 30s sudo waydroid shell -- /dev/magisk_waydroid/su -c "$MAGISK_BIN --sqlite \"REPLACE INTO settings (key, value) VALUES ('zygisk', 1)\"" || echo "Internal injection failed"
fi

#    # Force properties that Magisk checks early
    waydroid prop set persist.magisk.zygisk 1 || true
    waydroid prop set magiskhide_enable 1 || true
    
    log "Restarting Android Zygote to initialize Zygisk..."
    # We use a more aggressive method for Android 13: 
    # stop the framework, set properties, and start it again.
    sudo waydroid shell -- /dev/magisk_waydroid/su -c "setprop ctl.stop zygote" || true
    sudo waydroid shell -- /dev/magisk_waydroid/su -c "setprop ctl.stop zygote64" || true
    sudo waydroid shell -- /dev/magisk_waydroid/su -c "killall -9 zygote zygote64" || true
    sleep 2
    sudo waydroid shell -- /dev/magisk_waydroid/su -c "setprop ctl.start zygote" || true
    sudo waydroid shell -- /dev/magisk_waydroid/su -c "setprop ctl.start zygote64" || true
    
    log "Zygote restart triggered. Waiting for system to stabilize..."
    sleep 10

# =============================================================================
# PLAY INTEGRITY FIX
# =============================================================================

log "Fetching Latest PIF..."
PIF_URL="https://github.com/osm0sis/PlayIntegrityFork/releases/download/v16/PlayIntegrityFork-v16.zip"
curl -sL "$PIF_URL" -o "/tmp/$PIF_FILE" || log "PIF download failed"

if [ -f "/tmp/$PIF_FILE" ]; then
    sudo mkdir -p "$HOME/.local/share/waydroid/data/local/tmp" || true
    sudo cp "/tmp/$PIF_FILE" "$HOME/.local/share/waydroid/data/local/tmp/$PIF_FILE" || true
    info "Installing PIF module..."
    timeout 60s sudo waydroid shell -- /dev/magisk_waydroid/su -c "$MAGISK_BIN --install-module /data/local/tmp/$PIF_FILE" || log "Module install timed out"
fi

log ""
log "==========================================="
log "✅ Activation complete!"
log "==========================================="
log "Restart Waydroid manualy now: waydroid session stop && waydroid session start"
log "Then run 'just status' to check for :Z:H"
