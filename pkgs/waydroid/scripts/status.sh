#!/usr/bin/env bash
# Check Waydroid and Magisk status
set -euo pipefail

GREEN='\033[1;32m'
BLUE='\033[1;34m'
NC='\033[0m'

echo -e "${BLUE}=== Waydroid Status ===${NC}"
waydroid status 2>/dev/null || echo "Waydroid not running"

echo ""
echo -e "${BLUE}=== Waydroid Props ===${NC}"
echo "multi_windows: $(waydroid prop get persist.waydroid.multi_windows 2>/dev/null || echo 'not set')"
echo "fake_wifi:     $(waydroid prop get persist.waydroid.fake_wifi 2>/dev/null || echo 'not set')"
echo "mouse_mode:    $(waydroid prop get persist.waydroid.cursor_on_subsurface 2>/dev/null || echo 'not set')"
echo "fake_touch:    $(waydroid prop get persist.waydroid.fake_touch 2>/dev/null || echo 'not set')"

echo ""
echo -e "${BLUE}=== Magisk Version ===${NC}"
MAGISK_BIN="/dev/magisk_waydroid/magisk"
sudo waydroid shell -- /dev/magisk_waydroid/su -c "$MAGISK_BIN -v" 2>/dev/null || echo "Magisk not activated (run 'just activate')"

echo ""
echo -e "${BLUE}=== MagiskHide Status ===${NC}"
sudo waydroid shell -- /dev/magisk_waydroid/su -c "magiskhide status" 2>/dev/null || echo "Unknown"

echo ""
echo -e "${BLUE}=== Hidden Apps ===${NC}"
sudo waydroid shell -- /dev/magisk_waydroid/su -c "magiskhide ls" 2>/dev/null | head -10 || echo "None"

echo ""
echo -e "${BLUE}=== Installed Modules ===${NC}"
sudo waydroid shell -- ls /data/adb/modules/ 2>/dev/null || echo "No modules"

echo ""
echo -e "${GREEN}Tip: Run 'just show' to launch the UI${NC}"
