#!/usr/bin/env bash
# Get Android ID for device registration
set -euo pipefail

echo "Getting Android ID..."
android_id=$(sudo waydroid shell -- sh -c "sqlite3 /data/data/com.google.android.gsf/databases/gservices.db \"select value from main where name = 'android_id';\"" 2>/dev/null) || {
  echo "Error: Waydroid not running or GSF not installed"
  exit 1
}

echo ""
echo "Android ID: $android_id"
echo ""
echo "Register at: https://www.google.com/android/uncertified/"
