# nix-presets — shared service & desktop bundles

Reusable NixOS / home-manager modules consumed by multiple hosts across `nix-config`. Same Switchboard pattern as `nix-config/modules/nixos/` — every option under `my.*`, opt-out by default.

## Preset vs. module — which goes where?

- **`nix-presets/`** — anything used by ≥2 hosts OR conceptually portable (a service container, a desktop bundle, a code editor preset).
- **`nix-config/modules/nixos/`** — host-system concerns specific to this fleet (PKI, persistence layout, snapper, audit policies).

When in doubt, start in `nix-config/modules/nixos/`; promote to `nix-presets` once a second host needs it.

## Layout

| Path | Contents |
|---|---|
| `containers/` | NixOS containers (Caddy, n8n, code-server, Authelia, …). Options under `my.containers.<name>`. |
| `code-common/` | Shared VSCode / code-server settings, extensions, bundles. |
| `nixpak/` | Sandboxed application launchers. |
| `atlas/` | Workspace-Atlas integration. |
| `lib/` | Shared Nix helpers (TLS, roles, factory functions). |
| Top-level `.nix` files | Cross-cutting presets (firefox, git, terminal, mcp, opencode, …). |

`flake.nix` here exposes each preset as a `nixosModules.<name>` (or `homeManagerModules.<name>`). When adding a new preset, register it there too — otherwise hosts can't import it.

## Adding a container preset — checklist

1. Create `containers/<name>.nix` with `options.my.containers.<name>` (enable + the inputs that vary per host: IP, dataDir, secretsFile, …).
2. Register it in `flake.nix` under `nixosModules`.
3. Import it from a host: `inputs.nix-presets.nixosModules.<name>` in the imports list.
4. Opt in: `my.containers.<name>.enable = true;`.
5. From repo root, run `just maintenance::sync-agent` to refresh `../nix-config/docs/OPTIONS.md`.

## Don't

- Don't hardcode host-specific values (IPs, paths, secrets) — surface them as options.
- Don't import from `nix-config` here — presets must not depend back on the consumer.
