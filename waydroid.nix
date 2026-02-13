{ inputs, ... }: # Pass flake inputs as a function argument

{ ... }:

{
  imports = [
    inputs.nix-waydroid-setup.nixosModules.default
  ];

  # This one line now enables the core service, kernel params, bridge, and setup tools.
  programs.waydroid-setup.enable = true;
}
