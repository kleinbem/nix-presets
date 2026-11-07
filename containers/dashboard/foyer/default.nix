{ self, inputs }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.dashboard;

  foyerPkg =
    if inputs ? foyer && inputs.foyer ? packages then
      inputs.foyer.packages.${pkgs.system}.default
    else
      pkgs.foyer or (pkgs.writeShellScriptBin "foyer" "echo 'foyer package not provided' && exit 1");
in
{
  imports = [ (import ../options.nix { inherit lib; }) ];

  config = lib.mkIf cfg.enable (
    self.lib.mkContainer {
      inherit config;
      name = "dashboard-foyer";
      inherit cfg;
      innerConfig = {
        services.caddy = {
          enable = true;
          virtualHosts.":8082" = {
            extraConfig = ''
              root * ${foyerPkg}
              file_server
              try_files {path} {path}/ /200.html
            '';
          };
        };

        networking.firewall.allowedTCPPorts = [ 8082 ];
      };
    }
  );
}
