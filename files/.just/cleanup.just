# `os cleanup::*` — destructive personal-data cleanups (always confirm).

# Delete all Firefox profile folders that aren't the 'standard' one.
[confirm("🦊 Delete all Firefox profile folders that aren't 'standard'?")]
browsers:
    @echo "🦊 Cleaning browser profiles..."
    @find ~/.mozilla/firefox -maxdepth 1 -type d -name "*.default*" -not -path "*standard*" -delete

# Reset the Firefox 'laboratory' profile to a clean slate.
[confirm("🧪 Reset the Firefox Laboratory profile? All data in that profile will be lost.")]
firefox-laboratory:
    @echo "🧪 Resetting Laboratory profile..."
    @rm -rf ~/.mozilla/firefox/*.laboratory
    @firefox -P laboratory --headless &
    @sleep 3
    @pkill firefox
