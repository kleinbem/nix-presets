{ self, inputs }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.langfuse;
  inherit (self.lib) mkContainer;
in
{
  options.my.containers.langfuse = {
    enable = lib.mkEnableOption "Langfuse Telemetry Stack";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "4G";
    };
    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
  }
  // import ../lib/tls-options.nix { inherit lib; };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # 1. Native NixOS Database Container
      (mkContainer {
        inherit config;
        name = "langfuse-db";
        cfg = {
          inherit (cfg) autoStart;
          ip = "10.85.46.124/24"; # Static IP for the DB container
          hostDataDir = "${cfg.hostDataDir}/db";
        };
        innerConfig = {
          services.postgresql = {
            enable = true;
            package = pkgs.postgresql_16;
            enableTCPIP = true;
            authentication = lib.mkForce ''
              local all all trust
              host all all 10.85.46.0/24 trust
            '';
            initialScript = pkgs.writeText "init.sql" ''
              CREATE DATABASE langfuse;
              CREATE USER postgres WITH SUPERUSER PASSWORD 'postgres';
            '';
          };
          networking.firewall.allowedTCPPorts = [ 5432 ];
        };
        bindMounts = {
          "/var/lib/postgresql" = {
            hostPath = "${cfg.hostDataDir}/db";
            isReadOnly = false;
          };
        };
      })

      # 2. Native Application Container (migrated from OCI)
      (mkContainer {
        inherit config;
        name = "langfuse";
        cfg = {
          inherit (cfg) autoStart ip memoryLimit;
          inherit (cfg) hostDataDir;
          enableNesting = true; # Required for Podman-in-Nspawn
          tls = {
            enable = true;
            serverPort = 3000;
          };
        };
        innerConfig = {
          imports = [ inputs.nix-packages.nixosModules.langfuse ];
          nixpkgs.overlays = [ inputs.nix-packages.overlays.default ];
          networking.nameservers = [
            "1.1.1.1"
            "8.8.8.8"
          ];

          # Native Langfuse Service
          services.langfuse = {
            enable = true;
            environmentFile = if (cfg.secretsFile != null) then "/run/secrets/langfuse.env" else null;
            port = 3000;
            # Optional Clickhouse if you want to test it
            # clickhouse.enable = true;
          };

          networking.firewall.allowedTCPPorts = [ 3000 ];

        };
        bindMounts = lib.optionalAttrs (cfg.secretsFile != null) {
          "/run/secrets/langfuse.env" = {
            hostPath = cfg.secretsFile;
            isReadOnly = true;
          };
        };
      })

    ]
  );
}
