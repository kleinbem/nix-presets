# `os logs::*` — journald shortcuts.

# Follow the live journal.
follow:
    journalctl -f

# Show all messages from the current boot.
this-boot:
    journalctl -b 0 --no-hostname

# Show all messages from the previous boot.
last-boot:
    journalctl -b -1 --no-hostname
