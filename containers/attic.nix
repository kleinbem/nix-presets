{ self }:
{
  config,
  lib,
  pkgs,
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
    autoReap = {
      enable = lib.mkEnableOption ''
        a weekly systemd timer that reclaims orphaned chunks. atticd's retention
        GC marks superseded chunks deleted but does NOT unlink the files on this
        host, so ~24G of dead chunks accumulated once; this reaps them (see
        nix-presets/containers/attic.nix comments and the on-demand
        `just nixos::attic-reap` recipe)'';
      schedule = lib.mkOption {
        type = lib.types.str;
        # Sunday 05:30: after the ~04:00 autoUpgrade has finished pulling and
        # before workday pushes/CI builds — clear of both Attic readers and
        # writers. Run reaps AFTER build/deploy, never during.
        default = "Sun *-*-* 05:30:00";
        description = "systemd OnCalendar expression for the weekly reap.";
      };
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (mkContainer {
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
                # Much larger chunks than atticd's defaults (was avg 64 KiB / max
                # 256 KiB). core-pi is an RPi5: chunking a 300–750 MiB *unfree* app
                # (chrome, vscode, electron — not on cache.nixos.org, so they must be
                # pushed here) into ~12k tiny FastCDC/BLAKE3 chunks saturates its CPU,
                # the upload request stalls, and the client times out (os error 110).
                # ~64× bigger chunks = hundreds per NAR, not thousands → ingestible.
                # Costs some cross-path dedup, negligible here (each app is unique;
                # this is a sparse overlay, not a general cache).
                nar-size-threshold = 1048576; # 1 MiB: store smaller NARs whole
                min-size = 1048576; # 1 MiB
                avg-size = 4194304; # 4 MiB
                max-size = 16777216; # 16 MiB
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

                # Finite retention: 14 days (tightened from 90d on 2026-07-24). A DB
                # audit that day proved storage (37G / 41.7 GiB uncompressed) is ~100%
                # genuine overlay — 0 paths signed by cache.nixos.org, 2 by cachix; the
                # rest is unfree AI-tool apps + custom kernel + Android SDK, SEVERAL
                # VERSIONS each (openclaw/lmstudio/vscode/cursor keep old versions).
                # Attic has no "keep N versions" knob, so the retention window IS the
                # version-count lever: 14d evicts each superseded version ~2x faster
                # than 30d once it goes idle. Safe to tighten because the PUSH side
                # only uploads non-upstream paths (CI `--skip-cached` + the local
                # `push-cache` signature filter), so nothing a public cache has is at
                # risk — clients fetch those from cache.nixos.org anyway. This is SAFE
                # for the "devices must never
                # build" requirement because of a self-healing loop, not in spite of
                # it. The pieces:
                #
                #   1. GC deletes an object only when BOTH its created_at AND
                #      last_accessed_at are older than the window (server/src/gc.rs),
                #      so anything actively pulled renews itself and never ages out.
                #   2. If GC DOES evict a still-needed non-upstream path (e.g. the
                #      stable linux-rpi kernel, untouched for 14d), the next build-all
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
                # the costs are (a) a somewhat more frequent aarch64 kernel recompile
                # in CI when a cold path ages out, and (b) a rollback gap — rolling
                # `production` back to a closure whose unique paths are >14d old and
                # already evicted would make that host build. If you ever roll back
                # further than 14d, widen this first.
                #
                # Knobs: widen to "90 days"/"1 year" to cut recompiles + close the
                # rollback gap at the cost of disk; set "0" to disable age-based GC
                # entirely (keep-forever — unbounded disk, manual `just nixos::attic-gc`
                # only sweeps orphans then). Per-cache override: `attic cache configure
                # system --retention-period <dur>`.
                #
                # UPSTREAM FILTER (imperative — no declarative atticd knob exists):
                # atticd's server-side push filter skips paths signed by an upstream
                # cache's key. It defaults to cache.nixos.org-1 only; the four cachix
                # keys this flake trusts were added on 2026-07-24 via
                #   attic cache configure system \
                #     --upstream-cache-key-name cache.nixos.org-1 \
                #     --upstream-cache-key-name nix-community.cachix.org-1 \
                #     --upstream-cache-key-name devenv.cachix.org-1 \
                #     --upstream-cache-key-name cuda-maintainers.cachix.org-1 \
                #     --upstream-cache-key-name anduril.cachix.org-1
                # This is PER-CACHE DB state, NOT captured by this module — if the
                # cache DB is ever recreated, re-run the above (keep it in sync with
                # trusted-public-keys in nix-config/modules/nixos/core.nix).
                default-retention-period = "14 days";
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
      })

      # Host-level weekly reaper for orphaned chunks that atticd marks deleted but
      # never unlinks. Downtime-minimized: file deletion runs with atticd UP (the
      # chunks are unreferenced, never served); atticd is stopped only for the
      # quick DELETE+VACUUM. Guards: refuses if any deleted-marked chunk is still
      # referenced, and defers if a push is writing chunks right now.
      (lib.mkIf cfg.autoReap.enable {
        systemd.services.attic-reap = {
          description = "Reclaim orphaned Attic chunks (atticd's reaper leaves them on disk)";
          path = with pkgs; [
            sqlite
            systemd
            coreutils
            findutils
            gnused
          ];
          serviceConfig.Type = "oneshot";
          script = ''
            set -uo pipefail
            DB=${cfg.hostDataDir}/server.db
            ST=${cfg.hostDataDir}/storage
            trap 'systemctl -M attic start atticd 2>/dev/null || true' EXIT

            # Safety invariant: a deleted-marked chunk must never still be
            # referenced. If one is, refuse to touch anything.
            DANGER=$(sqlite3 "file:$DB?immutable=1" \
              "SELECT count(*) FROM chunk WHERE state='D' AND holders_count>0;")
            if [ "$DANGER" != "0" ]; then
              echo "ABORT: $DANGER deleted-marked chunks still referenced — refusing to reap"
              exit 1
            fi

            # Never interrupt a push: skip if any chunk was written in the last
            # 3 min (a build is pushing). Persistent timer retries next window.
            if find "$ST" -type f -name '*.chunk' -mmin -3 -print -quit 2>/dev/null | grep -q .; then
              echo "recent chunk writes (push in progress) — deferring to next window"
              exit 0
            fi

            LIST=$(mktemp)
            sqlite3 "file:$DB?immutable=1" \
              "SELECT json_extract(remote_file,'$.Local.name') FROM chunk WHERE state='D' AND holders_count=0;" > "$LIST"
            N=$(wc -l < "$LIST")
            if [ "$N" -eq 0 ]; then echo "nothing to reap"; rm -f "$LIST"; exit 0; fi

            BEFORE=$(du -sh "$ST" | cut -f1)
            # Slow part, kept online: delete the orphaned files. Sharded layout is
            # storage/<c1>/<c1c2>/<name>.chunk.
            sed -E "s#^((.)(.).*)#$ST/\2/\2\3/\1#" "$LIST" | xargs -r -P4 rm -f

            # Only the DB writes need atticd stopped (seconds on a compacted DB).
            systemctl -M attic stop atticd
            sleep 2
            cp -a "$DB" "$DB.pre-reap.bak" 2>/dev/null || true
            sqlite3 "$DB" "DELETE FROM chunk WHERE state='D' AND holders_count=0;"
            sqlite3 "$DB" "VACUUM;"
            systemctl -M attic start atticd

            rm -f "$LIST"
            AFTER=$(du -sh "$ST" | cut -f1)
            echo "attic-reap: storage $BEFORE -> $AFTER, removed $N orphaned chunks"
          '';
        };
        systemd.timers.attic-reap = {
          description = "Weekly Attic orphaned-chunk reap";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.autoReap.schedule;
            Persistent = true;
            RandomizedDelaySec = "20m";
          };
        };
      })
    ]
  );
}
