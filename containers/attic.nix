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
    upstreamCacheKeyNames = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      example = [
        "cache.nixos.org-1"
        "nix-community.cachix.org-1"
      ];
      description = ''
        Signing key names of the public caches Attic sits on top of. Pushes
        skip paths signed by any of them, so the cache holds only what no
        public cache has. Applied to the `system` cache on every activation
        that changes the list; null leaves the cache's setting alone.
      '';
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
        # atticd reads its env file from /etc/atticd-env, not the factory's
        # default /run/secrets/attic.env.
        inherit (cfg) secretsFile;
        secretsFilePath = "/etc/atticd-env";
        innerConfig = inner: {
          services.atticd = {
            enable = true;
            # zhaofengli/attic#376: chunk holds were released by detached tasks
            # that fail silently under load, so chunks stayed held forever and
            # GC never freed them. Drop once merged.
            package = inner.pkgs.attic-server.overrideAttrs (old: {
              patches = (old.patches or [ ]) ++ [
                (inner.pkgs.fetchpatch {
                  name = "attic-release-chunk-holds.patch";
                  url = "https://github.com/zhaofengli/attic/commit/651f59712dfac1d4e29ddc9b169021237c2a3219.patch";
                  hash = "sha256-/NMj9FKigyOaw94qm1QFvukRNjuG6JPhHpHXxo/KVuY=";
                })
              ];
            });
            environmentFile = if cfg.secretsFile != null then "/etc/atticd-env" else null;
            settings = {
              listen = "[::]:8080";
              api-endpoint = "https://cache.kleinbem.dev/";
              storage = {
                type = "local";
                path = "/var/lib/atticd/storage";
              };
              chunking = {
                # Much larger chunks than atticd's defaults. On a Pi 5, chunking a large
                # unfree app (chrome, vscode) into thousands of small chunks saturates
                # the CPU and the client upload times out (os error 110). The lost
                # dedup is negligible since each app here is unique.
                nar-size-threshold = 1048576; # 1 MiB: store smaller NARs whole
                min-size = 1048576; # 1 MiB
                avg-size = 4194304; # 4 MiB
                max-size = 16777216; # 16 MiB
              };

              # atticd's default is zstd 8. Measured on core-pi (Pi 5, one core,
              # 214 MB of typical libraries): level 3 compresses ~3x faster than
              # 8 for 10% more bytes; level 1 is faster again but 26% bigger,
              # which costs on every pull over the mesh. Only new chunks use it.
              compression = {
                type = "zstd";
                level = 3;
              };

              # This cache only holds paths no public cache has, so retention can be short.
              garbage-collection = {
                # Every pass also sweeps orphaned chunks, regardless of retention.
                interval = "12 hours";

                # No "keep N versions" knob: GC drops a path neither created nor pulled
                # within the window. CI build-all re-pushes evicted paths still in use,
                # and promote-production's verify-cache gate waits for them. Gotcha:
                # rolling `production` back more than 14 days can make a host build;
                # widen the window first.
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

          # Applies upstreamCacheKeyNames to the `system` cache. The token is
          # minted here from the server's own secret and lives for 10 minutes,
          # so no admin token has to be stored anywhere. The key list is part
          # of the script, so a changed list re-runs the unit on activation.
          systemd.services.attic-upstream-keys = lib.mkIf (cfg.upstreamCacheKeyNames != null) (
            let
              innerAtticd = inner.config.services.atticd;
              serverToml = (pkgs.formats.toml { }).generate "server.toml" innerAtticd.settings;
            in
            {
              description = "Set the upstream cache keys of the Attic system cache";
              after = [ "atticd.service" ];
              requires = [ "atticd.service" ];
              wantedBy = [ "multi-user.target" ];
              path = [
                innerAtticd.package
                pkgs.attic-client
                pkgs.curl
              ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                EnvironmentFile = lib.mkIf (cfg.secretsFile != null) "/etc/atticd-env";
              };
              script = ''
                set -euo pipefail
                for _ in $(seq 60); do
                  curl -s -o /dev/null http://127.0.0.1:8080/ && break
                  sleep 1
                done
                token=$(atticadm -f ${serverToml} make-token --sub attic-upstream-keys \
                  --validity 10m --pull system --configure-cache system \
                  --configure-cache-retention system)
                export XDG_CONFIG_HOME=$(mktemp -d)
                trap 'rm -rf "$XDG_CONFIG_HOME"' EXIT
                attic login --set-default local http://127.0.0.1:8080 "$token" >/dev/null
                attic cache configure system ${
                  lib.concatMapStringsSep " " (
                    k: "--upstream-cache-key-name ${lib.escapeShellArg k}"
                  ) cfg.upstreamCacheKeyNames
                }
                attic cache info system | grep 'Upstream Cache Keys'
              '';
            }
          );
        };
        bindMounts = {
          "/var/lib/atticd" = {
            hostPath = cfg.hostDataDir;
            isReadOnly = false;
          };
        };
      })

      # Weekly reaper for chunks atticd marks deleted but never unlinks. Files are
      # removed with atticd up (they're unreferenced); atticd stops only for the
      # DELETE+VACUUM. Refuses if a marked chunk is still referenced, and defers
      # while a push is writing chunks.
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

            # Leaked holds (zhaofengli/attic#376): a chunk keeps holders_count>0
            # with no chunkref left, or a NAR upload stays pending forever, and
            # atticd's GC never collects either. Older than a day can't be a
            # live upload. Released here, atticd's next GC pass deletes them.
            CUTOFF="strftime('%Y-%m-%dT%H:%M:%S','now','-1 day')"
            STALE_NARS="SELECT id FROM nar WHERE state='P' AND holders_count=0 AND created_at < $CUTOFF"
            STALE_HOLDS="FROM chunk WHERE state='V' AND holders_count>0 AND created_at < $CUTOFF
              AND NOT EXISTS (SELECT 1 FROM chunkref r WHERE r.chunk_id=chunk.id)"
            LEAKS=$(sqlite3 "file:$DB?immutable=1" \
              "SELECT (SELECT count(*) FROM ($STALE_NARS)) + (SELECT count(*) $STALE_HOLDS);")

            if [ "$N" -eq 0 ] && [ "$LEAKS" -eq 0 ]; then echo "nothing to reap"; rm -f "$LIST"; exit 0; fi

            BEFORE=$(du -sh "$ST" | cut -f1)
            # Slow part, kept online: delete the orphaned files. Sharded layout is
            # storage/<c1>/<c1c2>/<name>.chunk.
            sed -E "s#^((.)(.).*)#$ST/\2/\2\3/\1#" "$LIST" | xargs -r -P4 rm -f

            # Only the DB writes need atticd stopped (seconds on a compacted DB).
            # chunkrefs are deleted by hand: the sqlite3 CLI doesn't enforce the
            # ON DELETE CASCADE.
            systemctl -M attic stop atticd
            sleep 2
            cp -a "$DB" "$DB.pre-reap.bak" 2>/dev/null || true
            sqlite3 "$DB" "BEGIN;
              DELETE FROM chunk WHERE state='D' AND holders_count=0;
              DELETE FROM chunkref WHERE nar_id IN ($STALE_NARS);
              DELETE FROM nar WHERE id IN ($STALE_NARS);
              UPDATE chunk SET holders_count=0 WHERE id IN (SELECT id $STALE_HOLDS);
              COMMIT;"
            sqlite3 "$DB" "VACUUM;"
            systemctl -M attic start atticd

            rm -f "$LIST"
            AFTER=$(du -sh "$ST" | cut -f1)
            echo "attic-reap: storage $BEFORE -> $AFTER, removed $N orphaned chunks, released $LEAKS leaked holds"
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
