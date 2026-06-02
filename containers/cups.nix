{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.cups;
  inherit (self.lib) mkContainer;
in
{
  options.my.containers.cups = {
    enable = lib.mkEnableOption "CUPS Print Server Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "1G";
    };
    privateUsers = lib.mkOption {
      type = lib.types.str;
      default = "no";
    };
  };

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "cups";
    inherit cfg;

    # Needs to be able to scan for USB printers
    enableUSB = true;

    innerConfig =
      { pkgs, ... }:
      {
        nixpkgs.overlays = [ self.inputs.nix-packages.overlays.default ];
        nixpkgs.config.allowUnfree = true;
        services.printing = {
          enable = true;
          # Include the custom Ricoh driver and generic ones
          drivers = [
            pkgs.ricoh-driver
            pkgs.brlaser
            pkgs.gutenprint
          ];
          listenAddresses = [ "*:631" ];
          allowFrom = [ "all" ];
          browsing = true;
          defaultShared = true;
          startWhenNeeded = false; # Ensure service is ready for ensurePrinters
          stateless = true;
          extraConf = ''
            DefaultEncryption Never
            ServerAlias *
          '';
        };

        # Declaratively ensure the Ricoh printer is configured
        hardware.printers = {
          ensurePrinters = [
            {
              name = "Ricoh_SP_220Nw_Legacy";
              deviceUri = "socket://10.0.5.10:9100";
              model = "ricoh/RICOH-SP-220Nw.ppd";
              ppdOptions = {
                PageSize = "A4";
              };
            }
          ];
          ensureDefaultPrinter = "Ricoh_SP_220Nw_Legacy";
        };

        networking = {
          firewall = {
            allowedTCPPorts = [
              631
              9100
            ];
            allowedUDPPorts = [
              631
              5353
            ];
          };

          interfaces.eth0.ipv4.routes = [
            {
              address = "10.0.0.0";
              prefixLength = 16;
              # Route through the host's bridge IP (per-host; was hard-coded to
              # nixos-nvme's 10.85.46.1, which broke routing on core-pi).
              via = config.my.network.hostAddress;
            }
          ];
        };

        # Ensure Avahi works for mDNS printer discovery
        services.avahi = {
          enable = true;
          nssmdns4 = true;
          publish = {
            enable = true;
            userServices = true;
          };
        };
      };

    bindMounts = lib.mkIf (cfg.hostDataDir != null) {
      "/var/lib/cups" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    };
  });
}
