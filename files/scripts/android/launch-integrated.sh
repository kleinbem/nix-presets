#!/usr/bin/env bash

# Integrated Emulator Launcher
# Launches a headless emulator and attaches scrcpy for UI.

AVD_NAME="NixIntegratedDev"
SYSTEM_IMAGE="system-images;android-36;google_apis_playstore;x86_64"

# 1. Create AVD if needed
if ! avdmanager list avd -c | grep -q "^$AVD_NAME$"; then
  echo "Creating AVD: $AVD_NAME using $SYSTEM_IMAGE"
  # 'no' answers "Do you wish to create a custom hardware profile? [no]"
  echo "no" | avdmanager create avd -n "$AVD_NAME" -k "$SYSTEM_IMAGE" --force
else
  echo "AVD $AVD_NAME already exists."
fi

# 2. Launch Emulator (Headless)
echo "Starting Emulator ($AVD_NAME) in headless mode..."
emulator "@$AVD_NAME" \
  -no-window \
  -no-audio \
  -gpu host \
  -memory 4096 \
  -feature -ClipboardSharing \
  &

EMULATOR_PID=$!

# Trap to kill emulator when script exits
trap "kill $EMULATOR_PID" EXIT

# 3. Wait for ADB
echo "Waiting for device..."
adb wait-for-device

# Optional: Poll specifically for boot completion if needed, 
# but scrcpy usually handles connecting to a partially booted device fairly well.
echo "Waiting for boot completion..."
while [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" != "1" ]; do
  sleep 1
done

# 4. Launch scrcpy
echo "Launching scrcpy..."
scrcpy --serial emulator-5554 \
  --window-title "Integrated Android ($AVD_NAME)" \
  --always-on-top \
  --stay-awake \
  --shortcut-mod=lctrl,lalt

# When scrcpy exits, the script ends, triggering the trap to kill the emulator.
