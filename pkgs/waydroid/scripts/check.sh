#!/usr/bin/env bash
# Check Waydroid and Magisk status with colored OK/NOK
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[1;34m'
NC='\033[0m'

echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}[*] Waydroid Health Check${NC}"
echo -e "${BLUE}==========================================${NC}"

# 1. Waydroid Session
if waydroid status 2>/dev/null | grep -q "Session:.*RUNNING"; then
    echo -e "[*] Waydroid Session:  ${GREEN}OK${NC}"
else
    echo -e "[*] Waydroid Session:  ${RED}NOK${NC} (Not running)"
fi

# 2. Magisk Daemon
MAGISK_VER=$(sudo waydroid shell -- sh -c "magisk -v 2>/dev/null" || echo "failed")
if [[ "$MAGISK_VER" == *"delta"* ]] || [[ "$MAGISK_VER" == *"MAGISK"* ]]; then
    echo -e "[*] Magisk Daemon:     ${GREEN}OK${NC} ($MAGISK_VER)"
else
    echo -e "[*] Magisk Daemon:     ${RED}NOK${NC} (Not active - run 'just activate')"
fi

# 3. Root Access
if sudo waydroid shell -- /dev/magisk_waydroid/su -c "id" 2>/dev/null | grep -q "uid=0"; then
    echo -e "[*] Root Access:       ${GREEN}OK${NC}"
else
    echo -e "[*] Root Access:       ${RED}NOK${NC} (Failed)"
fi

# 4. Integrity Module
MODULES=$(sudo waydroid shell -- ls /data/adb/modules/ 2>/dev/null || echo "")
if echo "$MODULES" | grep -qi "playintegrityfix"; then
    echo -e "[*] Integrity Module:  ${GREEN}OK${NC}"
else
    echo -e "[*] Integrity Module:  ${RED}NOK${NC} (Missing - check Magisk app modules)"
fi

# 5. ARM Translation (Houdini)
if sudo waydroid shell -- ls /system/lib/libhoudini.so 2>/dev/null | grep -q "houdini"; then
    echo -e "[*] ARM Translation:   ${GREEN}OK${NC}"
else
    echo -e "[*] ARM Translation:   ${RED}NOK${NC}"
fi

echo -e "${BLUE}==========================================${NC}"
