#!/usr/bin/env bash
# Uninstall Magisk and patches from Waydroid
set -euo pipefail

echo "This will remove Magisk and all patches from Waydroid."
echo "Press Ctrl+C to cancel, or Enter to continue..."
read -r

echo "Stopping Waydroid..."
waydroid container stop 2>/dev/null || true

echo "Removing overlay data..."
sudo rm -rf /var/lib/waydroid/overlay/* 2>/dev/null || true
sudo rm -rf "${HOME}/.local/share/waydroid/data/adb" 2>/dev/null || true
sudo rm -rf "${HOME}/.local/share/waydroid/data/local/tmp/"*.zip 2>/dev/null || true

echo ""
echo "Done! Run 'waydroid upgrade -o' to restore clean images."
