# `os notes::*` — Obsidian vault helpers.

# Append a quick note to the Obsidian Inbox.
add message="":
    @echo "📝 Capturing note..."
    @echo "- [ ] {{message}} (Captured on $(date))" >> $HOME/Documents/Notes/Inbox.md

# Launch Obsidian in the background.
open:
    @obsidian &

# Run the Obsidian vault housekeeping script.
organize:
    @bash ~/Develop/github.com/kleinbem/nix/scripts/organize-notes.sh

# Vault integrity check.
check:
    @echo "🏠 Checking vault integrity..."
    @bash ~/Develop/github.com/kleinbem/nix/scripts/vault-health.sh

# Symlink the workspace docs/ into Obsidian's Notes tree.
link-docs:
    @echo "🔗 Linking workspace docs into Obsidian..."
    @ln -sf ~/Develop/github.com/kleinbem/nix/docs $HOME/Documents/Notes/Project-Docs
