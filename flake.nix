{
  description = "Shared Modules & Presets";

  outputs = { ... }: {
    nixosModules = {
      # Add modules here
      # example = import ./modules/example.nix;
    };
    homeManagerModules = {
       # Add modules here
    };
  };
}
