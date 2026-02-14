#!/usr/bin/env bash

# Scrcpy Client - Connects to the running Daemon
# Usage: launch-scrcpy-client

ADB_SERIAL="emulator-5554"

echo "🖥️ Connecting to Integrated Android..."

# Check if device is connected
if ! adb devices | grep -q -E "$ADB_SERIAL"'[[:space:]]+device'; then
    echo "❌ Error: Emulator is not running or not ready."
    echo "Check the 'android-emulator' user service: systemctl --user status android-emulator"
    exit 1
fi

# Launch scrcpy
scrcpy --serial "$ADB_SERIAL" \
    --window-title "Integrated Android (Zotac)" \
    --always-on-top \
    --stay-awake \
    --shortcut-mod=lctrl,lalt \
    --forward-all-clicks \
    "$@"
