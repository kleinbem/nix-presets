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

NixOS presets default to `enable = false`; the host opts in under `my.*`.
Of the Home Manager modules, `herdr`, `mcp` and `opencode` have a
`modules.<name>.enable` switch; `desktop`, `dx`, `terminal` and `vcs` apply
their config as soon as they are imported.
