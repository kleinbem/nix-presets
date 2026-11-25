# nix-presets Justfile
#
# Reusable NixOS / home-manager modules consumed by hosts in nix-config.
# Containers, desktop bundles, code-editor presets, MCP servers, …

[group("Main")]
default:
    @just --list

[group("Linter")]
check:
    @echo "🧩 Verifying presets flake..."
    @nix flake check . --impure

[group("Linter")]
fmt:
    @nix fmt

# --- Discovery ---

# List every nixosModule the flake exposes (alphabetical).
[group("Discovery")]
list-presets:
    @echo "📋 Available nixosModules:"
    @nix eval .#nixosModules --apply 'builtins.attrNames' --json 2>/dev/null \
        | jq -r '.[]' 2>/dev/null \
        || nix flake show . 2>/dev/null | sed -n '/nixosModules/,/^[a-z]/p'

# List home-manager modules.
[group("Discovery")]
list-hm-modules:
    @echo "🏠 Available homeManagerModules:"
    @nix eval .#homeManagerModules --apply 'builtins.attrNames' --json 2>/dev/null \
        | jq -r '.[]' 2>/dev/null \
        || nix flake show .

# --- Build helpers ---

# Build a single preset's NixOS test (when defined under checks).
[group("Build")]
build-check name:
    @nix build .#checks.x86_64-linux.{{name}}
