#!/usr/bin/env bash
set -euo pipefail

ARG="${1:-}"

if [ -z "$ARG" ]; then
    echo "Usage: $0 <path-to-apk | url | fdroid | aurora>"
    exit 1
fi

APK_URL=""
APK_PATH=""
IS_TEMP="no"

# Shortcuts
if [ "$ARG" = "fdroid" ]; then
    APK_URL="https://f-droid.org/F-Droid.apk"
elif [ "$ARG" = "aurora" ]; then
    APK_URL="https://f-droid.org/repo/com.aurora.store_72.apk"
elif [[ "$ARG" =~ ^https?:// ]]; then
    APK_URL="$ARG"
else
    APK_PATH="$ARG"
fi

echo "🔄 Waiting for device..."
adb wait-for-device

# Download if needed
if [ -n "$APK_URL" ]; then
    echo "⬇️ Downloading APK from $APK_URL..."
    TEMP_APK="/tmp/sideload_$(date +%s).apk"
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$TEMP_APK" "$APK_URL"
    elif command -v curl >/dev/null 2>&1; then
        curl -s -L -o "$TEMP_APK" "$APK_URL"
    else
        echo "❌ Error: Neither wget nor curl found."
        exit 1
    fi
    APK_PATH="$TEMP_APK"
    IS_TEMP="yes"
fi

# Validation
if [ ! -f "$APK_PATH" ]; then
    echo "❌ Error: File not found: $APK_PATH"
    exit 1
fi

echo "📱 Installing $APK_PATH..."
if adb install -r "$APK_PATH"; then
    echo "✅ Successfully installed!"
else
    echo "❌ Installation failed."
    exit 1
fi

# Cleanup
if [ "$IS_TEMP" = "yes" ]; then
    rm -f "$APK_PATH"
fi
