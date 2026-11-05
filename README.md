# Nix Presets

This repository contains shared NixOS and Home Manager modules/presets.

## Modules

*Currently empty - ready for population.*

## Usage

Import this flake to access shared modules.

```nix
inputs.nix-presets.url = "github:kleinbem/nix-presets";
# ...
modules = [
  inputs.nix-presets.nixosModules.some-module
];
```
