{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.github-runner;
  inherit (self.lib) mkContainer;

  # OpenWrt / heavy-build toolchain — opt in per runner via `buildTools = true`.
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

  runnerOpts = lib.types.submodule (
    { name, ... }:
    {
      options = {
        url = lib.mkOption {
          type = lib.types.str;
          example = "https://github.com/kleinbem/nix-config";
          description = "Repo (or org) URL this runner registers against.";
        };
        name = lib.mkOption {
          type = lib.types.str;
          default = "github-runner-${name}";
          defaultText = lib.literalExpression ''"github-runner-''${attrName}"'';
          description = "Runner name shown in the GitHub Actions UI.";
        };
        extraLabels = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ "nixos" ];
          description = "Labels ADDED to the defaults (self-hosted, Linux, X64). Target with `runs-on: [self-hosted, <label>]`.";
        };
        extraPackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
          description = "Extra packages on the runner's PATH.";
        };
        buildTools = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Add the OpenWrt/heavy-build toolchain (gcc/make/perl/python/…) to this runner.";
        };
        unlockPodman = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Drop the systemd sandbox (all caps, no syscall filter, user namespaces) so rootless podman / bwrap / nested containers work. Needed for OpenWrt firmware builds.";
        };
      };
    }
  );
in
{
  options.my.containers.github-runner = {
    enable = lib.mkEnableOption "GitHub Actions runner container (opt-in — no standing workflow targets self-hosted)";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    secretsFile = lib.mkOption {
      type = lib.types.str;
      description = "Host path to a file holding the GitHub runner registration token (bind-mounted to /run/secrets/github-runner-token).";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "8G";
    };
    runners = lib.mkOption {
      type = lib.types.attrsOf runnerOpts;
      default = { };
      description = "Runners to run in this container, keyed by systemd service suffix. Empty = the container comes up idle (toggle a runner in when you need one).";
      example = lib.literalExpression ''
        {
          nix-config = { url = "https://github.com/kleinbem/nix-config"; extraLabels = [ "nixos" "debug" ]; };
          openwrt    = { url = "https://github.com/kleinbem/openwrt-builder"; extraLabels = [ "openwrt" "filogic" ]; buildTools = true; unlockPodman = true; };
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "github-runner";
    inherit cfg;

    # rootless podman + user namespaces inside the container
    enableNesting = true;

    innerConfig =
      { pkgs, ... }:
      let
        baseOverrides = {
          DynamicUser = false;
          User = "github-runner";
          Group = "github-runner";
        };
        podmanUnlock = {
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
        };
      in
      {
        services.github-runners = lib.mapAttrs (_: r: {
          enable = true;
          ephemeral = true; # auto-deregister after each job — avoids stale-credential failures
          replace = true;
          inherit (r) url name;
          tokenFile = "/run/secrets/github-runner-token";
          extraLabels = r.extraLabels;
          extraPackages = [
            pkgs.git
          ]
          ++ lib.optionals r.buildTools (commonBuildInputs pkgs)
          ++ r.extraPackages
          ++ lib.optional r.unlockPodman pkgs.podman;
          serviceOverrides = baseOverrides // (lib.optionalAttrs r.unlockPodman podmanUnlock);
        }) cfg.runners;

        systemd.services = lib.mkMerge [
          (lib.mapAttrs' (
            n: _:
            lib.nameValuePair "github-runner-${n}" {
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];
            }
          ) cfg.runners)
          {
            github-runner-cleanup = lib.mkIf (cfg.runners != { }) {
              description = "Wipe GitHub runner _work dirs";
              startAt = "daily";
              serviceConfig = {
                Type = "oneshot";
                User = "github-runner";
                ExecStart = pkgs.writeShellScript "gh-runner-cleanup" ''
                  for d in ${lib.concatStringsSep " " (lib.attrNames cfg.runners)}; do
                    rm -rf "/var/lib/github-runners/$d/_work" || true
                  done
                '';
              };
            };
          }
        ];

        users.users.github-runner = {
          isNormalUser = true;
          group = "github-runner";
          autoSubUidGidRange = true; # rootless podman
        };
        users.groups.github-runner = { };
      };

    bindMounts = {
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
