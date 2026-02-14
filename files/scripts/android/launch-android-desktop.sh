#!/usr/bin/env bash

# --- Android Launcher V6.6 (Input Stack Restoration) ---
set -euo pipefail

# 1. Defaults
AVD_NAME=""
MODE="scrcpy"  # Default integrated mode
ARGS_TO_PASS=()
GPU_ACCEL="sw" # Default safe software rendering
USE_WINDOW="no"
USE_SCRCPY="yes"
PERF_LEVEL="standard"
USE_YUBIKEY="no"
COMPAT_MODE="no"

ROOTABLE="no"

# 1.1 Cleanup Function
cleanup_zombies() {
    echo "🧹 Checking for zombie processes..."
    # Kill specific AVD instances
    pkill -f "emulator.*-avd.*NixIntegrated" || true
    # Kill internal QEMU process (often missed by emulator kill)
    pkill -f "qemu-system.*NixIntegrated" || true
    # Kill scrcpy for default emulator port
    pkill -f "scrcpy.*emulator-5554" || true
    # Kill stuck crashpad handlers
    pkill -f "crashpad_handler.*AndroidEmulator" || true
    # Kill netsimd (often holds locks)
    pkill -f "netsimd.*AndroidEmulator" || true
    # Remove stale locks
    rm -f "$HOME"/.android/avd/*.avd/*.lock
    sleep 1
}

# Run cleanup before anything else
cleanup_zombies

# 2. Argument Parsing (Robust)
for arg in "$@"; do
    case "$arg" in
        --native)    MODE="native";    GPU_ACCEL="hw"; USE_WINDOW="yes"; USE_SCRCPY="no"; PERF_LEVEL="max" ;;
        --hybrid)    MODE="hybrid";    GPU_ACCEL="hw"; USE_WINDOW="yes"; USE_SCRCPY="yes"; PERF_LEVEL="max" ;;
        --scrcpy-hw) MODE="scrcpy-hw"; GPU_ACCEL="hw"; USE_WINDOW="no";  USE_SCRCPY="yes"; PERF_LEVEL="max" ;;
        --scrcpy-sw) MODE="scrcpy-sw"; GPU_ACCEL="sw"; USE_WINDOW="no";  USE_SCRCPY="yes"; PERF_LEVEL="standard" ;;
        --yubikey)   USE_YUBIKEY="yes" ;;
        --rootable)  ROOTABLE="yes" ;;
        --compat)    COMPAT_MODE="yes" ;; # New flag for black screen fixes
        --*)         ARGS_TO_PASS+=("$arg") ;; # Pass through unknown flags
        *)           AVD_NAME="$arg" ;;        # Assume positional is AVD name
    esac
done

# 3. Memory & CPU Allocation
if [ "$PERF_LEVEL" = "max" ]; then
    RAM_MB=8192
    HEAP_SIZE="1024M"
    CORES=8
else
    RAM_MB=4096
    HEAP_SIZE="512M"
    CORES=4
fi

# 4. Auto-detect AVD
if [ "$ROOTABLE" = "yes" ]; then
    AVD_NAME="NixIntegratedRoot"
    echo "🔓 MODE: Rootable (Google APIs) selected."
elif [ -z "$AVD_NAME" ] || [ "$AVD_NAME" = "--" ]; then
    if command -v emulator >/dev/null 2>&1; then
        # Filter for the standard Dev AVD if it exists, otherwise take first available
        AVD_NAME=$(emulator -list-avds | grep "NixIntegratedDev" | head -n 1 || true)
        if [ -z "$AVD_NAME" ]; then
             AVD_NAME=$(emulator -list-avds | grep -v "INFO" | head -n 1 || true)
        fi
    fi
    AVD_NAME="${AVD_NAME:-NixIntegratedDev}"
    echo "🔍 Using AVD: $AVD_NAME"
fi

# 4.1 Ensure AVD Exists (Auto-Create)
if ! avdmanager list avd -c | grep -q "^$AVD_NAME$"; then
    echo "⚠️  AVD '$AVD_NAME' not found. Creating it now..."
    
    if [ "$AVD_NAME" = "NixIntegratedRoot" ]; then
        IMG="system-images;android-36;google_apis;x86_64"
    else
        IMG="system-images;android-36;google_apis_playstore;x86_64"
    fi
    
    echo "no" | avdmanager create avd -n "$AVD_NAME" -k "$IMG" --force
    echo "✅ AVD '$AVD_NAME' created successfully."
fi

echo "🚀 Mode: $MODE (GPU: $GPU_ACCEL, RAM: ${RAM_MB}MB, Cores: $CORES, YubiKey: $USE_YUBIKEY, Compat: $COMPAT_MODE)"

# 5. Build Base Flags
FLAGS=(
    -avd "$AVD_NAME"
    -memory "$RAM_MB"
    -no-boot-anim
    -skin 1080x2400
    -multidisplay "1,3200,1440,480,0"
    -camera-back webcam0
    -accel on
)

# ⌨️  Input Fix V6.6: Re-enable VirtioInput but force legacy USB devices
# Disabling VirtioInput broke mouse. We re-enable it (by removing the disable flag)
# but we explicitly add USB devices to ensure they take precedence if Virtio fails.
# We also use 'virtio-mouse-pci' if possible, but 'usb-tablet' is safer for absolute pointing.
# Strategy: DEFAULT (Enable VirtioInput) + USB Fallbacks
QEMU_FLAGS=("-usb" "-device" "usb-tablet" "-device" "usb-kbd")

# 🔑 Hardware Security Key (Opt-in)
if [ "$USE_YUBIKEY" = "yes" ]; then
    echo "🔍 Scanning for YubiKey..."
    if command -v lsusb >/dev/null 2>&1; then
        YUBIKEY_INFO=$(lsusb | grep "1050:" | head -n 1 || true)
        if [ -n "$YUBIKEY_INFO" ]; then
            PID=$(echo "$YUBIKEY_INFO" | cut -d: -f3 | cut -d' ' -f1)
            echo "🛡️  Attaching YubiKey (1050:$PID). NOTE: Host access will be disabled until emulator stops."
            QEMU_FLAGS+=("-device" "usb-host,vendorid=0x1050,productid=0x$PID")
        else
            echo "⚠️  Warning: --yubikey requested but no Yubico device found in lsusb."
        fi
    else
        echo "❌ Error: lsusb not found. Cannot perform USB passthrough."
    fi
fi

# GPU & Window Logic
# 🛡️ Compatibility Mode for Secure Apps (Bitwarden Black Screen Fix)
if [ "$COMPAT_MODE" = "yes" ]; then
    echo "🛡️  Compatibility Mode Enabled: Forcing SwiftShader (Software GPU) to fix black screens..."
    FLAGS+=(-gpu swiftshader_indirect -feature -Vulkan)
    unset MESA_LOADER_DRIVER_OVERRIDE # Disable iris override
else
    if [ "$GPU_ACCEL" = "hw" ]; then
        FLAGS+=(-gpu host -feature Vulkan)
        export MESA_LOADER_DRIVER_OVERRIDE=iris
    else
        FLAGS+=(-gpu swiftshader_indirect -feature -Vulkan)
        unset MESA_LOADER_DRIVER_OVERRIDE
    fi
fi

[ "$USE_WINDOW" = "no" ] && FLAGS+=(-no-window)

# CPU Passthrough
if [ "$PERF_LEVEL" = "max" ]; then
    FLAGS+=(-cores "$CORES")
    QEMU_FLAGS+=(-cpu host)
fi

# 6. Pre-launch Maintenance & Config Injection
AVD_DIR="$HOME/.android/avd/${AVD_NAME}.avd"
if [ -d "$AVD_DIR" ]; then
    find "$AVD_DIR" -name "*.lock" -delete
    
    CONFIG_INI="$AVD_DIR/config.ini"
    if [ -f "$CONFIG_INI" ]; then
        echo "🔧 Injecting Config into $CONFIG_INI..."
        update_config() {
            local key="$1"
            local value="$2"
            if grep -q "^$key =" "$CONFIG_INI"; then
                sed -i "s/^$key =.*/$key = $value/" "$CONFIG_INI"
            else
                echo "$key = $value" >> "$CONFIG_INI"
            fi
        }
        update_config "hw.keyboard" "yes"
        update_config "hw.mainKeys" "no"
        update_config "hw.ramSize" "$RAM_MB"
        update_config "vm.heapSize" "$HEAP_SIZE"
        
        # Verify injection
        grep "hw.keyboard" "$CONFIG_INI" || echo "⚠️ Warning: hw.keyboard not found in config!"
    fi
fi

# 7. Launch Emulator
echo "🎬 Starting Emulator..."

if command -v steam-run >/dev/null 2>&1; then
    echo "steam-run emulator ${FLAGS[*]} ${ARGS_TO_PASS[*]} -qemu ${QEMU_FLAGS[*]}" > /tmp/emulator-cmd.log
    steam-run emulator "${FLAGS[@]}" "${ARGS_TO_PASS[@]}" -qemu "${QEMU_FLAGS[@]}" > /tmp/emulator.log 2>&1 &
else
    emulator "${FLAGS[@]}" "${ARGS_TO_PASS[@]}" -qemu "${QEMU_FLAGS[@]}" > /tmp/emulator.log 2>&1 &
fi
EMU_PID=$!

# 8. Wait for System Ready
echo "⏳ Waiting for Android..."
sleep 5
adb wait-for-device

while [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" != "1" ]; do
    kill -0 "$EMU_PID" 2>/dev/null || { echo "❌ Emulator died. Check /tmp/emulator.log"; exit 1; }
    sleep 2
done

# 9. Post-Boot Configuration (Enabling Developer Mode & Desktop UX)
echo "✅ Configured. Applying System Overrides..."
adb shell settings put global development_settings_enabled 1 || true
adb shell settings put global force_desktop_mode_on_external_displays 1 || true
adb shell settings put global enable_freeform_windows 1 || true

# 🪄 UX Fix: Force Navigation Bar / Taskbar visibility
echo "🪄 Tuning Taskbar for Desktop Mode..."
adb shell settings put secure navigation_mode 0 || true

# Audio & Desktop Trigger
adb emu avd hostmicon || true
adb shell am broadcast -a com.android.emulator.multidisplay.START -n com.android.emulator.multidisplay/.MultiDisplayServiceReceiver --user 0 >/dev/null 2>&1 || true

# 10. Launch Scrcpy Clients
SCRCPY_PIDS=()
if [ "$USE_SCRCPY" = "yes" ]; then
    SCRCPY_ARGS=("--max-size=1080" "--video-bit-rate=4M" "--no-audio" "--verbosity=verbose")

    echo "📺 Opening Scrcpy windows (Logs: /tmp/scrcpy.log)..."
    scrcpy -s emulator-5554 --window-title "Phone" "${SCRCPY_ARGS[@]}" > /tmp/scrcpy.log 2>&1 &
    SCRCPY_PIDS+=($!)
    sleep 1
    scrcpy -s emulator-5554 --display-id=2 --window-title "Desktop" "${SCRCPY_ARGS[@]}" >> /tmp/scrcpy.log 2>&1 &
    SCRCPY_PIDS+=($!)
fi

echo "✨ System Ready."
wait "$EMU_PID"
kill "${SCRCPY_PIDS[@]}" 2>/dev/null || true
