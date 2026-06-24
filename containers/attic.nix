{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.attic;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.attic = {
    enable = lib.mkEnableOption "Attic Binary Cache Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path to environment file containing ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64";
    };
    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "attic";
    inherit cfg;
    innerConfig = _: {
      services.atticd = {
        enable = true;
        environmentFile = if cfg.secretsFile != null then "/etc/atticd-env" else null;
        settings = {
          listen = "[::]:8080";
          api-endpoint = "https://cache.kleinbem.dev/";
          storage = {
            type = "local";
            path = "/var/lib/atticd/storage";
          };
          chunking = {
            nar-size-threshold = 65536;
            min-size = 16384;
            avg-size = 65536;
            max-size = 262144;
          };

          # Retention policy. This cache is a SPARSE OVERLAY on cache.nixos.org:
          # CI pushes only the paths it actually built — the non-upstream ones
          # (custom linux-rpi kernel, custom packages, host-specific config) —
          # because nix-fleet-setup runs attic-action with `skip-push` and lets
          # `nix-fast-build --attic-cache system --skip-cached` do the targeted
          # push. So everything here is, by construction, stuff no public cache
          # has.
          garbage-collection = {
            # How often atticd runs GC. Every pass ALWAYS sweeps orphaned chunks
            # (NAR data no longer referenced by any cache entry) regardless of
            # retention, AND applies the retention window below. 12h keeps storage
            # tidy without thrashing.
            interval = "12 hours";

            # Finite retention: 90 days. This is SAFE for the "devices must never
            # build" requirement because of a self-healing loop, not in spite of
            # it. The pieces:
            #
            #   1. GC deletes an object only when BOTH its created_at AND
            #      last_accessed_at are older than the window (server/src/gc.rs),
            #      so anything actively pulled renews itself and never ages out.
            #   2. If GC DOES evict a still-needed non-upstream path (e.g. the
            #      stable linux-rpi kernel, untouched for 90d), the next build-all
            #      rebuilds it (its `--skip-cached` finds it cached NOWHERE) and
            #      re-pushes it — refilling the current closure on CI, never on a
            #      device.
            #   3. The promote-production `verify-cache` gate then proves the full
            #      union (Attic + cache.nixos.org + mirrors) covers every deployed
            #      closure BEFORE advancing the `production` tag. So an eviction
            #      that hasn't been refilled blocks promotion (visible CI failure)
            #      instead of reaching a device as an on-device build.
            #
            # Net trade for bounded, automated disk: devices still never build;
            # the costs are (a) an occasional aarch64 kernel recompile in CI when
            # a cold path ages out (~quarterly at worst), and (b) a rollback gap —
            # rolling `production` back to a closure whose unique paths are >90d
            # old and already evicted would make that host build. If you ever roll
            # back further than 90d, widen this first.
            #
            # Knobs: widen to "180 days"/"1 year" to cut recompiles + close the
            # rollback gap at the cost of disk; set "0" to disable age-based GC
            # entirely (keep-forever — unbounded disk, manual `just nixos::attic-gc`
            # only sweeps orphans then). Per-cache override: `attic cache configure
            # system --retention-period <dur>`.
            default-retention-period = "90 days";
          };
        };
      };

      systemd.services.atticd.serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = lib.mkForce "root";
        Group = lib.mkForce "root";

        # Disable all sandboxing/hardening that conflicts with the container runtime (seccomp/namespaces/etc)
        CapabilityBoundingSet = lib.mkForce null;
        DeviceAllow = lib.mkForce null;
        DevicePolicy = lib.mkForce null;
        LockPersonality = lib.mkForce false;
        MemoryDenyWriteExecute = lib.mkForce false;
        NoNewPrivileges = lib.mkForce false;
        PrivateDevices = lib.mkForce false;
        PrivateTmp = lib.mkForce false;
        PrivateUsers = lib.mkForce false;
        ProcSubset = lib.mkForce null;
        ProtectClock = lib.mkForce false;
        ProtectControlGroups = lib.mkForce false;
        ProtectHome = lib.mkForce false;
        ProtectHostname = lib.mkForce false;
        ProtectKernelLogs = lib.mkForce false;
        ProtectKernelModules = lib.mkForce false;
        ProtectKernelTunables = lib.mkForce false;
        ProtectProc = lib.mkForce "default";
        ProtectSystem = lib.mkForce "no";
        RestrictAddressFamilies = lib.mkForce null;
        RestrictNamespaces = lib.mkForce false;
        RestrictRealtime = lib.mkForce false;
        RestrictSUIDSGID = lib.mkForce false;
        SystemCallArchitectures = lib.mkForce null;
        SystemCallFilter = lib.mkForce null;
      };

      networking.firewall.allowedTCPPorts = [ 8080 ];
    };
    bindMounts = {
      "/var/lib/atticd" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    }
    // lib.optionalAttrs (cfg.secretsFile != null) {
      "/etc/atticd-env" = {
        hostPath = cfg.secretsFile;
        isReadOnly = true;
      };
    };
  });
}
