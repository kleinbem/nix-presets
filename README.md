# Nix Presets

Shared NixOS and Home Manager modules/presets for the kleinbem fleet.

## Modules

- `nixosModules`: service containers (`forgejo`, `vaultwarden`, `ollama`, …), host
  services (`backup-engine`, `sandboxed-apps`, `attic-push`, …) and `all`, which
  imports all of them except `dashboard-homer`.
- `homeManagerModules`: `desktop`, `dx`, `herdr`, `mcp`, `opencode`, `terminal`, `vcs`.

Full lists: `just list-presets` and `just list-hm-modules`.

## Usage

```nix
inputs.nix-presets.url = "github:kleinbem/nix-presets";
# ...
modules = [
  inputs.nix-presets.nixosModules.sandboxed-apps
];
```

Presets default to `enable = false`; the host opts in (`my.*` for NixOS,
`modules.*` for Home Manager).
