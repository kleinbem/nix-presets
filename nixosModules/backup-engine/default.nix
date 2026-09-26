# backup-engine — generic, host-level backup for the fleet.
#
# WHAT is backed up is declared by the data owners themselves: presets and
# modules add `my.backup.items.<name>` whenever their service is enabled
# (they import this file by path — the module system dedups it, so the
# options exist wherever any such preset is imported). WHERE it goes and
# with which keys is fleet wiring (nix-config/modules/nixos/backup.nix).
# A host only sets `my.backup.enable = true` plus any host-only paths.
#
# Two tiers:
#   secure — small + critical (DB dumps, keys, CAs). One dated tarball,
#            age-encrypted to `secure.recipients`, copied to every
#            destination under <remote>/secure/<host>/. Restore needs only
#            an age identity + tar; no repo password, no running service.
#   bulk   — large data. restic, one independent repo per destination at
#            <remote>/restic/<host> (one provider being down never blocks
#            the other).
#
# Databases are always DUMPED (sqlite `.backup`, pg_dumpall) into a staging
# dir, never file-copied live: tar/restic read a datadir file-by-file over
# time, which is not the atomic snapshot crash recovery assumes.
#
# Units: backup-secure.service, restic-backups-bulk-<dest>.service,
# backup-freshness-check.service, backup-notify-failure@.service.
# Test: checks/backup-engine.nix (NixOS VM, full backup + restore).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.backup;
  inherit (lib) types mkOption;

  tiers = [
    "secure"
    "bulk"
  ];

  postgresType = types.submodule {
    options = {
      machine = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "nspawn machine (`machinectl list`) Postgres runs in; null = this host.";
      };
      podman = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Name of the podman container running Postgres (inside `machine`, if set); null = native Postgres.";
      };
      user = mkOption {
        type = types.str;
        default = "postgres";
        description = "Postgres superuser to dump as (system user for native, -U role for podman).";
      };
    };
  };

  itemType = types.submodule {
    options = {
      tier = mkOption {
        type = types.enum tiers;
        description = "secure = small/critical, age-encrypted bundle; bulk = restic.";
      };
      paths = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Absolute paths backed up as-is.";
      };
      exclude = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "/var/lib/vaultwarden/db.sqlite3*" ];
        description = "Absolute glob patterns excluded from `paths`.";
      };
      sqlite = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "SQLite DB files copied consistently via `.backup` (exclude the live files from `paths`).";
      };
      postgres = mkOption {
        type = types.listOf postgresType;
        default = [ ];
        description = "Postgres clusters dumped with pg_dumpall.";
      };
      command = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Escape hatch: shell command whose stdout is stored as <item>/command.dump.";
      };
    };
  };

  destinationType = types.submodule {
    options = {
      remote = mkOption {
        type = types.str;
        example = "r2:kleinbem-backup";
        description = "rclone remote + base path; tiers land under <remote>/secure/<host> and <remote>/restic/<host>.";
      };
      rcloneConfigFile = mkOption {
        type = types.str;
        description = "Path to the rclone config defining the remote (e.g. a sops secret path).";
      };
      tiers = mkOption {
        type = types.listOf (types.enum tiers);
        default = tiers;
      };
      required = mkOption {
        type = types.bool;
        default = true;
        description = "Secure tier: a failed upload here fails the run (false = warn + notify only).";
      };
      pruneSecureAfterDays = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = "Delete secure bundles older than this from the destination after each upload. Leave null where the bucket itself expires them (and core-pi-style locked buckets can't delete anyway).";
      };
      resticExtraOptions = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "restic `-o` options for this destination's repo (e.g. rclone.args tuning).";
      };
    };
  };

  host = cfg.hostName;
  agePluginPkgs =
    lib.optional (lib.any (lib.hasPrefix "age1yubikey1") cfg.secure.recipients) pkgs.age-plugin-yubikey
    ++ cfg.secure.agePlugins;
  itemsOf = tier: lib.filterAttrs (_: i: i.tier == tier) cfg.items;
  secureItems = itemsOf "secure";
  bulkItems = itemsOf "bulk";
  destsFor = tier: lib.filterAttrs (_: d: builtins.elem tier d.tiers) cfg.destinations;
  secureDests = destsFor "secure";
  bulkDests = destsFor "bulk";
  hasSecure = secureItems != { } && secureDests != { };
  hasBulk = bulkItems != { } && bulkDests != { };

  allOf = attr: items: lib.concatLists (lib.mapAttrsToList (_: i: i.${attr}) items);
  esc = lib.escapeShellArg;

  notifyCmd =
    if cfg.notify.command != null then
      cfg.notify.command
    else
      toString (
        pkgs.writeShellScript "backup-notify-log" ''
          prio="$1"; title="$2"; shift 2
          ${pkgs.util-linux}/bin/logger -t backup -p "user.$([ "$prio" = high ] && echo err || echo notice)" "$title: $*"
        ''
      );

  pgCmd =
    pg:
    let
      run = "${pkgs.systemd}/bin/systemd-run --machine=${pg.machine} --pipe --wait --quiet --collect";
      podmanDump = "podman exec ${esc pg.podman} pg_dumpall -U ${esc pg.user}";
    in
    if pg.machine == null && pg.podman == null then
      "${pkgs.util-linux}/bin/runuser -u ${esc pg.user} -- ${config.services.postgresql.package}/bin/pg_dumpall"
    else if pg.machine == null then
      "/run/current-system/sw/bin/${podmanDump}"
    else if pg.podman == null then
      "${run} --uid=${esc pg.user} /run/current-system/sw/bin/pg_dumpall"
    else
      "${run} /run/current-system/sw/bin/${podmanDump}";

  pgLabel =
    pg:
    lib.concatStringsSep "-" (
      [ (if pg.machine == null then "host" else pg.machine) ]
      ++ lib.optional (pg.podman != null) pg.podman
    );

  # `<script> <outdir>` → <outdir>/<item>/{<sqlite basename>,postgres-*.sql,command.dump}
  mkDumpScript =
    tier: items:
    pkgs.writeShellScript "backup-dump-${tier}" ''
      set -euo pipefail
      umask 077
      out="$1"
      rm -rf "$out"
      mkdir -p "$out"
      ${lib.concatStrings (
        lib.mapAttrsToList (name: item: ''
          mkdir -p "$out"/${esc name}
          ${lib.concatMapStrings (p: ''
            ${pkgs.sqlite}/bin/sqlite3 ${esc p} ".backup '$out/${name}/${baseNameOf p}'"
          '') item.sqlite}
          ${lib.concatMapStrings (pg: ''
            ${pgCmd pg} > "$out"/${esc name}/postgres-${pgLabel pg}.sql
            test -s "$out"/${esc name}/postgres-${pgLabel pg}.sql
          '') item.postgres}
          ${lib.optionalString (item.command != null) ''
            ( ${item.command} ) > "$out"/${esc name}/command.dump
            test -s "$out"/${esc name}/command.dump
          ''}
        '') items
      )}
    '';

  inherit (cfg) stateDir;
  marker = job: "${stateDir}/${job}.last-success";
  touchMarker = job: "${pkgs.coreutils}/bin/touch ${marker job}";
  jobs =
    lib.optional hasSecure "secure"
    ++ lib.optionals hasBulk (map (d: "bulk-${d}") (lib.attrNames bulkDests));

  # External dead-man's switch (healthchecks.io-style ping URLs):
  #   <baseUrl>/<ping key>/<host>-backup-<job>        on success
  #   <baseUrl>/<ping key>/<host>-backup-<job>/fail   from the OnFailure unit
  # Best-effort: a failed ping never fails the backup itself — the external
  # service alerting on the *missing* ping is the whole point.
  hb = cfg.heartbeat;
  heartbeat = pkgs.writeShellScript "backup-heartbeat" ''
    set -u
    key=$(${pkgs.coreutils}/bin/tr -d '[:space:]' < ${esc (toString hb.pingKeyFile)} 2>/dev/null) || exit 0
    [ -n "$key" ] || exit 0
    url="${hb.baseUrl}/$key/${host}-backup-$1''${2:+/$2}"
    ${pkgs.curl}/bin/curl -fsS -m 10 --retry 3 -o /dev/null "$url" \
      || echo "WARN: heartbeat ping for $1''${2:+ ($2)} failed" >&2
  '';
  hbPing = job: lib.optionalString (hb.pingKeyFile != null) "${heartbeat} ${job}";

  secureScript =
    let
      paths = allOf "paths" secureItems;
      excludes = allOf "exclude" secureItems;
    in
    ''
      set -euo pipefail
      umask 077
      ts=$(date -u +%Y%m%dT%H%M%SZ)
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      ${mkDumpScript "secure" secureItems} "$work/stage/dumps"

      # tar exit 1 = "file changed as we read it" on live paths: acceptable
      # (dumps are the consistent part); anything above 1 is fatal.
      rc=0
      tar --anchored ${
        lib.concatMapStringsSep " " (e: "--exclude=${esc (lib.removePrefix "/" e)}") excludes
      } \
        -czf "$work/bundle.tar.gz" -C "$work/stage" dumps \
        ${
          lib.optionalString (paths != [ ])
            "-C / ${lib.concatMapStringsSep " " (p: esc (lib.removePrefix "/" p)) paths}"
        } \
        || rc=$?
      [ "$rc" -le 1 ] || exit "$rc"

      name=${esc host}-$ts.tar.gz.age
      age ${lib.concatMapStringsSep " " (r: "-r ${esc r}") cfg.secure.recipients} \
        -o "$work/$name" "$work/bundle.tar.gz"
      rm -f "$work/bundle.tar.gz"
      sha256sum "$work/$name" | cut -d' ' -f1 > "$work/$name.sha256"

      failed=0
      ${lib.concatStrings (
        lib.mapAttrsToList (dname: d: ''
          dst=${esc "${d.remote}/secure/${host}"}
          if rclone --config ${esc d.rcloneConfigFile} copyto "$work/$name" "$dst/$name" \
            && rclone --config ${esc d.rcloneConfigFile} copyto "$work/$name.sha256" "$dst/$name.sha256"; then
            echo "secure → ${dname}: ok"
            ${lib.optionalString (d.pruneSecureAfterDays != null) ''
              rclone --config ${esc d.rcloneConfigFile} delete --min-age ${toString d.pruneSecureAfterDays}d "$dst" \
                || echo "WARN: prune on ${dname} failed" >&2
            ''}
          else
            ${
              if d.required then
                ''
                  echo "ERROR: secure → ${dname} failed" >&2
                  failed=1
                ''
              else
                ''
                  echo "WARN: secure → ${dname} (best-effort) failed" >&2
                  ${notifyCmd} default ${esc "${host} backup"} "secure upload to best-effort destination ${dname} failed"
                ''
            }
          fi
        '') secureDests
      )}
      [ "$failed" -eq 0 ]
      ${touchMarker "secure"}
      ${hbPing "secure"}
      echo "secure backup $ts ok ($(du -h "$work/$name" | cut -f1))"
    '';

  bulkStage = d: "${stateDir}/staging/bulk-${d}";
in
{
  options.my.backup = {
    enable = lib.mkEnableOption "host backups (units for the registered my.backup.items)";

    warnIfDisabled = mkOption {
      type = types.bool;
      default = true;
      description = "Emit an eval warning when services registered backup items but my.backup.enable is false.";
    };

    hostName = mkOption {
      type = types.str;
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "Per-host path component in every destination.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/backup";
    };

    items = mkOption {
      type = types.attrsOf itemType;
      default = { };
      description = "What to back up. Mostly set by presets/modules for their own data.";
    };

    destinations = mkOption {
      type = types.attrsOf destinationType;
      default = { };
    };

    secure = {
      recipients = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "age recipients the secure bundle is encrypted to.";
      };
      agePlugins = mkOption {
        type = types.listOf types.package;
        default = [ ];
        description = ''
          Extra age plugins put on the secure unit's PATH. Plugin recipients
          (`age1<name>1…`) need the plugin binary even just to ENCRYPT — the
          hardware is only needed to decrypt. age-plugin-yubikey is added
          automatically for `age1yubikey1…` recipients; list others here.
        '';
      };
      schedule = mkOption {
        type = types.str;
        default = "*-*-* 02:30:00";
      };
    };

    bulk = {
      passwordFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "restic repository password file (shared by all bulk destinations).";
      };
      schedule = mkOption {
        type = types.str;
        default = "*-*-* 03:15:00";
      };
      pruneOpts = mkOption {
        type = types.listOf types.str;
        default = [
          "--keep-daily 7"
          "--keep-weekly 4"
          "--keep-monthly 12"
        ];
      };
      checkOpts = mkOption {
        type = types.listOf types.str;
        default = [ "--read-data-subset=1%" ];
        description = "restic check after each run (empty list disables).";
      };
    };

    notify.command = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Executable called as `<cmd> <high|default> <title> <message>` on failures/staleness. null = syslog only.";
    };

    heartbeat = {
      pingKeyFile = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          File holding a healthchecks.io-style project ping key. When set,
          every job pings <baseUrl>/<key>/<host>-backup-<job> on success and
          …/fail on failure — an external dead-man's switch that still
          alerts when the host itself (and its local notify path) is dead.
        '';
      };
      baseUrl = mkOption {
        type = types.str;
        default = "https://hc-ping.com";
      };
    };

    jobs = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      description = "Backup jobs this host runs (secure, bulk-<dest>) — for external check provisioning; slugs are <hostName>-backup-<job>.";
    };

    freshness = {
      maxAgeHours = mkOption {
        type = types.ints.positive;
        default = 48;
      };
      schedule = mkOption {
        type = types.str;
        default = "*-*-* 08:00:00";
      };
    };
  };

  config = lib.mkMerge [
    {
      my.backup.jobs = if cfg.enable then jobs else [ ];
      warnings = lib.optional (!cfg.enable && cfg.warnIfDisabled && cfg.items != { }) (
        "my.backup: services on this host registered backup items ("
        + lib.concatStringsSep ", " (lib.attrNames cfg.items)
        + ") but my.backup.enable = false — nothing is being backed up."
      );
    }

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = secureItems == { } || (secureDests != { } && cfg.secure.recipients != [ ]);
          message = "my.backup: secure items exist but no secure destination or no secure.recipients.";
        }
        {
          assertion = secureItems == { } || lib.any (d: d.required) (lib.attrValues secureDests);
          message = "my.backup: secure items need at least one required destination.";
        }
        {
          assertion = bulkItems == { } || (bulkDests != { } && cfg.bulk.passwordFile != null);
          message = "my.backup: bulk items exist but no bulk destination or no bulk.passwordFile.";
        }
      ];

      services.restic.backups = lib.mapAttrs' (
        d: dest:
        lib.nameValuePair "bulk-${d}" {
          initialize = true;
          repository = "rclone:${dest.remote}/restic/${host}";
          inherit (dest) rcloneConfigFile;
          inherit (cfg.bulk) passwordFile pruneOpts checkOpts;
          extraOptions = dest.resticExtraOptions;
          backupPrepareCommand = "${mkDumpScript "bulk" bulkItems} ${bulkStage d}/dumps";
          backupCleanupCommand = "rm -rf ${bulkStage d}";
          paths = [ "${bulkStage d}/dumps" ] ++ allOf "paths" bulkItems;
          exclude = allOf "exclude" bulkItems;
          timerConfig = {
            OnCalendar = cfg.bulk.schedule;
            Persistent = true;
            RandomizedDelaySec = "30m";
          };
        }
      ) (lib.optionalAttrs hasBulk bulkDests);

      systemd = {
        tmpfiles.rules = [ "d ${stateDir} 0700 root root - -" ];

        services = lib.mkMerge [
          (lib.mapAttrs' (
            d: _:
            lib.nameValuePair "restic-backups-bulk-${d}" {
              # upstream's unit only has ssh on PATH; restic execs `rclone`.
              path = [ pkgs.rclone ];
              onFailure = [ "backup-notify-failure@restic-backups-bulk-${d}.service" ];
              serviceConfig.ExecStartPost = [
                (touchMarker "bulk-${d}")
              ]
              ++ lib.optional (hb.pingKeyFile != null) "${heartbeat} bulk-${d}";
            }
          ) (lib.optionalAttrs hasBulk bulkDests))

          (lib.mkIf hasSecure {
            backup-secure = {
              description = "Encrypted off-site backup of this host's secure-tier data";
              onFailure = [ "backup-notify-failure@backup-secure.service" ];
              wants = [ "network-online.target" ];
              after = [ "network-online.target" ];
              path = [
                pkgs.coreutils
                pkgs.gnutar
                pkgs.gzip
                pkgs.age
                pkgs.rclone
              ]
              ++ agePluginPkgs;
              serviceConfig = {
                Type = "oneshot";
                PrivateTmp = true;
                # `full`, not `strict`: rclone wants a writable cache under /root.
                ProtectSystem = "full";
              };
              script = secureScript;
            };
          })

          (lib.mkIf (jobs != [ ]) {
            backup-freshness-check = {
              description = "Alert when a backup job hasn't succeeded recently";
              serviceConfig.Type = "oneshot";
              path = [ pkgs.coreutils ];
              script = ''
                set -uo pipefail
                now=$(date +%s)
                max=${toString (cfg.freshness.maxAgeHours * 3600)}
                ${lib.concatMapStrings (job: ''
                  if [ ! -f ${marker job} ]; then
                    ${notifyCmd} high ${esc "${host} backup"} "${job}: no successful run yet"
                  elif [ $(( now - $(date -r ${marker job} +%s) )) -gt "$max" ]; then
                    ${notifyCmd} high ${esc "${host} backup"} "${job} STALE: last success $(date -u -r ${marker job} +%FT%TZ)"
                  fi
                '') jobs}
              '';
            };

            "backup-notify-failure@" = {
              description = "Notify about failed backup unit %i";
              serviceConfig.Type = "oneshot";
              scriptArgs = "%i";
              script = ''
                ${notifyCmd} high ${esc "${host} backup FAILED"} "unit $1 failed — journalctl -u $1"
                ${lib.optionalString (hb.pingKeyFile != null) ''
                  # %i is the instance name — no ".service" suffix
                  case "$1" in
                    backup-secure | backup-secure.service) job=secure ;;
                    restic-backups-bulk-*) job=''${1#restic-backups-}; job=''${job%.service} ;;
                    *) job= ;;
                  esac
                  [ -z "$job" ] || ${heartbeat} "$job" fail
                ''}
              '';
            };
          })
        ];

        timers = lib.mkMerge [
          (lib.mkIf hasSecure {
            backup-secure = {
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnCalendar = cfg.secure.schedule;
                Persistent = true;
                RandomizedDelaySec = "20m";
              };
            };
          })
          (lib.mkIf (jobs != [ ]) {
            backup-freshness-check = {
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnCalendar = cfg.freshness.schedule;
                Persistent = true;
              };
            };
          })
        ];
      };
    })
  ];
}
