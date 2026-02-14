#!/usr/bin/env bash
# Simulates a fingerprint touch on the Android Emulator
# Usage: ./simulate-fingerprint.sh [finger_id]
FINGER_ID="${1:-1}"
echo "👆 Simulating Fingerprint Touch (ID: $FINGER_ID)..."
adb -e emu finger touch "$FINGER_ID"
echo "✅ Done."
