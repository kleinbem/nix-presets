#!/usr/bin/env bash

# Vault Launcher - Persistent, secure Android environment
# Usage: launch-vault [AVD_NAME] [EXTRA_FLAGS...]

# Default AVD Name
AVD_NAME="${ANDROID_VAULT_AVD_NAME:-${1:-MySecureVault}}"
if [ -z "${ANDROID_VAULT_AVD_NAME:-}" ]; then
    shift || true
fi

# --- AVD Management ---
SYSTEM_IMAGE="${ANDROID_SYSTEM_IMAGE:-system-images;android-36;google_apis_playstore;x86_64}"
if ! avdmanager list avd -c | grep -q "^$AVD_NAME$"; then
    echo "📦 Creating Vault AVD: $AVD_NAME using $SYSTEM_IMAGE"
    echo "no" | avdmanager create avd -n "$AVD_NAME" -k "$SYSTEM_IMAGE" --force
else
    echo "✅ Vault AVD $AVD_NAME exists."
fi

# Flags for Persistence and Security
# Runtime Config
MEMORY_SIZE="${ANDROID_EMULATOR_MEMORY:-4096}"
# Vault specific defaults (writable system, no snapshot) are kept, but memory is configurable
FLAGS=(
    -avd "$AVD_NAME"
    -no-snapshot-load   # Do not load from a snapshot state (clean boot from disk image)
    -writable-system    # Allow system modifications if needed (or minimal persistence)
    -netdelay none
    -netspeed full
    -memory "$MEMORY_SIZE"
)

# Add GPU mode if specified
if [ -n "${ANDROID_EMULATOR_GPU_MODE:-}" ]; then
    FLAGS+=(-gpu "${ANDROID_EMULATOR_GPU_MODE}")
fi

# Add extra flags if specified
if [ -n "${ANDROID_EMULATOR_FLAGS:-}" ]; then
    # Split by space robustly
    read -ra EXTRA_FLAGS_ARRAY <<< "${ANDROID_EMULATOR_FLAGS}"
    FLAGS+=("${EXTRA_FLAGS_ARRAY[@]}")
fi

echo "Starting Vault ($AVD_NAME)..."
echo "Flags: ${FLAGS[*]} $*"

if command -v steam-run &> /dev/null; then
    steam-run emulator "${FLAGS[@]}" "$@" &
else
    emulator "${FLAGS[@]}" "$@" &
fi
