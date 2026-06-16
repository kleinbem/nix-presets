# `os system::*` — system configuration management.

FLAKE_PATH := "~/Develop/github.com/kleinbem/nix/nix-config"

# Rebuild + activate the system configuration.
rebuild:
    nh os switch --ask --diff always {{FLAKE_PATH}}

# Smart rebuild — checks build count first to skip no-op rebuilds.
rebuild-smart:
    {{FLAKE_PATH}}/scripts/smart-switch.sh {{FLAKE_PATH}}

# Roll back to the previous system generation.
rollback:
    nh os switch --rollback {{FLAKE_PATH}}

# Show generation history.
history:
    nix profile history --profile /nix/var/nix/profiles/system

# Diff the closures between the booted and current system.
changelogs:
    nix store diff-closures /run/booted-system /run/current-system

# Reboot into the BIOS/UEFI firmware setup.
bios:
    systemctl reboot --firmware-setup

# Verify Nix store integrity.
verify-store:
    nix-store --verify --check-contents

# Garbage-collect the Nix store + prune old system generations + podman cache.
clean:
    @echo "🧹 Cleaning Nix Store (keeping 3 generations)..."
    nh clean all --keep 3
    @echo "🔄 Optimizing Nix store..."
    nix-store --optimise
    @echo "🧹 Pruning Host Podman Cache..."
    podman system prune -f
    @if systemctl is-active --quiet container@langfuse.service; then \
        echo "🧹 Pruning Nested Langfuse Podman Cache..."; \
        sudo machinectl shell langfuse /run/current-system/sw/bin/podman system prune -f; \
    fi
    @echo "🧹 Cleaning Old System Generations..."
    sudo nix-collect-garbage --delete-older-than 3d
