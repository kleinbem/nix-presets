#!/usr/bin/env bash
# SOURCE OF TRUTH: nix-presets/files/scripts/android/simulate-fingerprint.sh
# Mirror at nix-devshells/shells/scripts/simulate-fingerprint.sh — keep in sync (drift check: `just maintenance::check-script-mirrors`).

# Simulates a fingerprint touch on the Android Emulator
# Usage: ./simulate-fingerprint.sh [finger_id]
FINGER_ID="${1:-1}"
echo "👆 Simulating Fingerprint Touch (ID: $FINGER_ID)..."
adb -e emu finger touch "$FINGER_ID"
echo "✅ Done."
