#!/usr/bin/env bash

# Emulator Daemon - running as Systemd Service
# Usage: launch-emulator-daemon

AVD_NAME="${ANDROID_AVD_NAME:-NixIntegratedDev}"
SYSTEM_IMAGE="${ANDROID_SYSTEM_IMAGE:-system-images;android-36;google_apis_playstore;x86_64}"
ADB_SERIAL="${ANDROID_ADB_SERIAL:-emulator-5554}"
TIMEOUT=300

# Argument Parsing
if [[ "$*" == *"--rootable"* ]]; then
    AVD_NAME="NixIntegratedRoot"
    SYSTEM_IMAGE="system-images;android-36;google_apis;x86_64"
    echo "🔓 MODE: Rootable (Google APIs) - No Play Store"
else
    echo "🔒 MODE: Standard (Play Store) - Default"
fi

echo "🚀 Starting Emulator Daemon: $AVD_NAME"

# 1. Create AVD if needed
if ! avdmanager list avd -c | grep -q "^$AVD_NAME$"; then
  echo "Creating AVD: $AVD_NAME using $SYSTEM_IMAGE"
  echo "no" | avdmanager create avd -n "$AVD_NAME" -k "$SYSTEM_IMAGE" --force
else
  echo "AVD $AVD_NAME exists."
fi

# 2. Launch Emulator (Headless, Backgrounded within script)
# We run it in background so we can run post-launch setup commands in this script.
# We will 'wait' for it at the end to keep the script (and systemd service) alive.
# Runtime Config
GPU_MODE="${ANDROID_EMULATOR_GPU_MODE:-swiftshader_indirect}"
MEMORY_SIZE="${ANDROID_EMULATOR_MEMORY:-4096}"
EXTRA_FLAGS="${ANDROID_EMULATOR_FLAGS:-}"
HEADLESS="${ANDROID_EMULATOR_HEADLESS:-true}"

ARGS=(
  "@$AVD_NAME"
  -no-audio
  -gpu "$GPU_MODE"
  -feature -Vulkan
  -no-snapshot-load
  -memory "$MEMORY_SIZE"
  -feature -ClipboardSharing
  -qemu -m "$MEMORY_SIZE"
)

if [ "$HEADLESS" = "true" ]; then
    ARGS+=("-no-window")
fi

echo "Starting Emulator process..."
steam-run emulator "${ARGS[@]}" $EXTRA_FLAGS &

EMULATOR_PID=$!

# Trap signals to shut down emulator cleanly
cleanup() {
    echo "Shutting down emulator..."
    kill $EMULATOR_PID
    wait $EMULATOR_PID
}
trap cleanup SIGINT SIGTERM EXIT

# 3. Wait for ADB
echo "⏳ Waiting for ADB connection..."
adb wait-for-device -s "$ADB_SERIAL"

# 4. Wait for Android Boot Completion
echo "⏳ Android is booting (Waiting for sys.boot_completed)..."
ITER=0
while [ "$(adb -s $ADB_SERIAL shell getprop sys.boot_completed | tr -d '\r')" != "1" ]; do
    sleep 2
    ITER=$((ITER + 2))
    if [ "$ITER" -gt "$TIMEOUT" ]; then
        echo "❌ Timeout: Android failed to boot within $TIMEOUT seconds."
        exit 1
    fi
done
echo "✅ Android Booted Successfully!"

# 5. Apply Settings
echo "⚙️ Applying persistent settings..."
# Prevent screen off and keep awake on power
adb -s "$ADB_SERIAL" shell settings put system screen_off_timeout 2147483647
adb -s "$ADB_SERIAL" shell settings put global stay_on_while_plugged_in 7

echo "✅ Daemon Ready. Listening for clients..."

# 6. Block until emulator exits
wait $EMULATOR_PID
