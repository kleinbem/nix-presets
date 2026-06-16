# `os fix::*` — quick fixes for known recurring issues.

# Fix YubiKey/Smartcard issues (restart pcscd & agents).
yubikey:
    pkill lxqt-openssh-askpass || true
    gpgconf --kill gpg-agent || true
    sudo systemctl restart pcscd

# Fix Chrome — restart shell + Chrome + YubiKey agents.
chrome:
    pkill -f gnome-shell || true
    pkill -f google-chrome || true
    just yubikey
    google-chrome-stable > /dev/null 2>&1 &
