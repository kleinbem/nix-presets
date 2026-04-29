{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.github-runner;
  inherit (self.lib) mkContainer;

  commonBuildInputs =
    pkgs: with pkgs; [
      git
      cachix
      gnumake
      gcc
      binutils
      bzip2
      gzip
      unzip
      gnutar
      wget
      curl
      rsync
      patch
      diffutils
      findutils
      gawk
      file
      which
      ncurses
      zlib
      openssl
      perl
      python3
      python3Packages.setuptools
      util-linux
      procps
    ];
in
{
  options.my.containers.github-runner = {
    enable = lib.mkEnableOption "GitHub Runner Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    secretsFile = lib.mkOption { type = lib.types.str; };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "8G";
    };
  };

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "github-runner";
    inherit cfg;

    # Enable nesting so rootless podman and user namespaces work inside the container
    enableNesting = true;

    innerConfig =
      { pkgs, ... }:
      {
        services.github-runners = {
          openwrt-builder = {
            enable = true;
            url = "https://github.com/kleinbem/openwrt-builder";
            tokenFile = "/run/secrets/github-runner-token";
            replace = true;
            name = "nixos-bpi-builder";
            extraLabels = [
              "nixos"
              "openwrt"
              "filogic"
            ];
            extraPackages =
              commonBuildInputs pkgs
              ++ (with pkgs; [
                podman
                shadow
              ]);
            serviceOverrides = {
              ProtectHome = "read-only";
              PrivateDevices = false;
              RestrictNamespaces = false;
              NoNewPrivileges = false;
              PrivateUsers = false;
              ProtectKernelTunables = false;
              RestrictAddressFamilies = [
                "AF_UNIX"
                "AF_INET"
                "AF_INET6"
                "AF_NETLINK"
              ];
              ProtectProc = "default";
              ProcSubset = "all";
              RestrictSUIDSGID = false;
              CapabilityBoundingSet = lib.mkForce [ "~" ];
              AmbientCapabilities = lib.mkForce [ ];
              SystemCallFilter = lib.mkForce [ ];
              DynamicUser = false;
              User = "github-runner";
              Group = "github-runner";
            };
          };
        };

        systemd.services."github-runner-openwrt-builder" = {
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
        };

        systemd.services.github-runner-cleanup = {
          description = "Cleanup GitHub Runner Workspace";
          startAt = "daily";
          serviceConfig = {
            Type = "oneshot";
            User = "github-runner";
            ExecStart = "${pkgs.coreutils}/bin/rm -rf /var/lib/github-runners/openwrt-builder/_work";
          };
        };

        users.users.github-runner = {
          isNormalUser = true;
          group = "github-runner";
          autoSubUidGidRange = true; # Required for rootless podman
        };
        users.groups.github-runner = { };
      };

    bindMounts = {
      # Bind mount the host data dir to /var/lib/github-runners so the runner has persistent state
      "/var/lib/github-runners" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
      "/run/secrets/github-runner-token" = {
        hostPath = cfg.secretsFile;
        isReadOnly = true;
      };
    };
  });
}
