# NixOS VM test for nixosModules/backup-engine: real backup AND restore of
# both tiers against a local rclone remote, plus the failure/staleness paths.
#   nix build .#checks.x86_64-linux.backup-engine
{ pkgs, module }:
let
  # TEST-ONLY keypair — generated for this VM test, protects nothing.
  agePub = "age1wrks5p2phce3znhnfj974frygk2dlpa69qw70wd7q4caljsm3c0s8rxzap";
  ageKey = "AGE-SECRET-KEY-1GFQZKXESH0R862VMN6ZY5WZMGRZ7U5ZCT2NQ3FEM8YCJP688PF4QTAG99C"; # gitleaks:allow test-only key, see above

  fixtures = pkgs.writeShellScriptBin "setup-fixtures" ''
    set -euo pipefail
    mkdir -p /srv/app/cache /srv/media
    echo secret-file > /srv/app/keep.pem
    mkdir -p /srv/extra && echo extra-file > /srv/extra/f
    echo junk > /srv/app/cache/x
    ${pkgs.sqlite}/bin/sqlite3 /srv/app/app.db "create table t(v); insert into t values('sqlite-canary');"
    echo photo > /srv/media/p.jpg
    echo tmp > /srv/media/x.tmp
    ${pkgs.sqlite}/bin/sqlite3 /srv/media/index.db "create table i(v); insert into i values('index-canary');"
  '';
in
pkgs.testers.runNixOSTest {
  name = "backup-engine";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ module ];

      # postgres, restic and rclone share one guest; 1 GiB (the default) is tight.
      virtualisation.memorySize = 2048;

      services.postgresql = {
        enable = true;
        initialScript = pkgs.writeText "init.sql" ''
          CREATE TABLE marker (v text);
          INSERT INTO marker VALUES ('pg-canary');
        '';
      };

      environment.systemPackages = [
        fixtures
        pkgs.sqlite
        pkgs.age
        pkgs.restic
        pkgs.rclone
        pkgs.gnutar
        pkgs.gzip
        pkgs.jq
      ];
      # Holds its database the way Music Assistant does: WAL in exclusive
      # locking mode, so no other process can read it while this runs.
      systemd.services.locker = {
        wantedBy = [ "multi-user.target" ];
        script = ''
          mkdir -p /srv/locked
          ${pkgs.python3}/bin/python3 - <<'PY'
          import sqlite3, time
          c = sqlite3.connect("/srv/locked/l.db", isolation_level=None)
          c.execute("PRAGMA locking_mode=exclusive")
          c.execute("PRAGMA journal_mode=WAL")
          c.execute("create table if not exists t(v)")
          c.execute("delete from t")
          c.execute("insert into t values('locked-canary')")
          open("/run/locker-ready", "w").close()
          time.sleep(1e9)
          PY
        '';
      };

      # Fake healthchecks endpoint: logs every request path, answers 200.
      systemd.services.fake-hc = {
        wantedBy = [ "multi-user.target" ];
        script = ''
          ${pkgs.python3}/bin/python3 - <<'PY'
          import http.server
          class H(http.server.BaseHTTPRequestHandler):
              def do_GET(self):
                  with open("/var/log/hc-pings", "a") as f:
                      f.write(self.path + "\n")
                  self.send_response(200); self.end_headers()
              do_POST = do_GET
              def log_message(self, *a): pass
          http.server.HTTPServer(("127.0.0.1", 8321), H).serve_forever()
          PY
        '';
      };

      environment.etc = {
        "backup-test/hc-key".text = "test-ping-key\n";
        "backup-test/rclone.conf".text = ''
          [dest]
          type = local
        '';
        "backup-test/restic-pw".text = "test-password";
        "backup-test/age-key".text = ageKey;
      };

      my.backup = {
        enable = true;
        items = {
          app = {
            tier = "secure";
            paths = [ "/srv/app" ];
            exclude = [
              "/srv/app/app.db*"
              "/srv/app/cache"
            ];
            sqlite = [ "/srv/app/app.db" ];
            postgres = [ { } ];
          };
          extra = {
            tier = "secure";
            # Fails once /run/break-dumps exists (last subtest).
            command = "[ ! -e /run/break-dumps ] && echo command-canary";
            paths = [ "/srv/extra" ];
          };
          media = {
            tier = "bulk";
            paths = [ "/srv/media" ];
            exclude = [
              "/srv/media/*.tmp"
              "/srv/media/index.db*"
            ];
            sqlite = [ "/srv/media/index.db" ];
          };
          locked = {
            tier = "bulk";
            sqlite = [ "/srv/locked/l.db" ];
            stopUnits = [ "locker.service" ];
            # Fails once /run/break-dumps exists (last subtest).
            command = "[ ! -e /run/break-dumps ] && echo bulk-command-canary";
          };
        };
        destinations = {
          primary = {
            remote = "dest:/srv/dest-a";
            rcloneConfigFile = "/etc/backup-test/rclone.conf";
          };
          # Remote not defined in the config → every upload fails.
          flaky = {
            remote = "missing:/nowhere";
            rcloneConfigFile = "/etc/backup-test/rclone.conf";
            required = false;
            pruneSecureAfterDays = 30;
          };
        };
        # Second recipient is a real (public) YubiKey recipient: proves the
        # engine puts age-plugin-yubikey on PATH — wrapping to it needs the
        # plugin but no hardware (caught live on core-pi 2026-09-26).
        secure.recipients = [
          agePub
          "age1yubikey1q2lhmqc0h6verf025hn62tkjkz25d760h54pdej7a55q4m2hszm8kwssfn0"
        ];
        bulk.passwordFile = "/etc/backup-test/restic-pw";
        heartbeat = {
          pingKeyFile = "/etc/backup-test/hc-key";
          baseUrl = "http://127.0.0.1:8321";
        };
        notify.command = toString (
          pkgs.writeShellScript "notify-to-file" ''
            echo "$@" >> /var/log/backup-notify
          ''
        );
      };
    };

  testScript = ''
    snapshots = (
        "RESTIC_PASSWORD_FILE=/etc/backup-test/restic-pw RCLONE_CONFIG=/etc/backup-test/rclone.conf "
        "restic -r rclone:dest:/srv/dest-a/restic/machine snapshots --json"
    )
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("postgresql.service")
    machine.succeed("setup-fixtures")
    machine.wait_for_open_port(8321)
    machine.wait_for_file("/run/locker-ready")
    # The lock is real: a reader is refused while locker runs.
    machine.fail("sqlite3 /srv/locked/l.db 'select v from t'")

    with subtest("secure tier: backup, decrypt, restore"):
        machine.succeed("systemctl start backup-secure.service")
        f = machine.succeed("ls /srv/dest-a/secure/machine/*.tar.gz.age").strip()
        assert not f.endswith("-partial.tar.gz.age"), f
        machine.succeed(f"test -s {f}.sha256")
        machine.succeed(f"mkdir /restore && age -d -i /etc/backup-test/age-key {f} | tar -xz -C /restore")
        machine.succeed("sqlite3 /restore/dumps/app/app.db 'select v from t' | grep sqlite-canary")
        machine.succeed("grep pg-canary /restore/dumps/app/postgres-host.sql")
        machine.succeed("grep command-canary /restore/dumps/extra/command.dump")
        machine.succeed("grep secret-file /restore/srv/app/keep.pem")
        machine.succeed("grep extra-file /restore/srv/extra/f")
        machine.fail("test -e /restore/srv/app/cache")
        machine.fail("test -e /restore/srv/app/app.db")
        machine.succeed("test -f /var/lib/backup/secure.last-success")
        # best-effort destination failed → notified, run still succeeded
        machine.succeed("grep 'best-effort destination flaky' /var/log/backup-notify")

    with subtest("bulk tier: restic backup + restore"):
        machine.succeed("systemctl start restic-backups-bulk-primary.service")
        machine.succeed(
            "RESTIC_PASSWORD_FILE=/etc/backup-test/restic-pw RCLONE_CONFIG=/etc/backup-test/rclone.conf "
            "restic -r rclone:dest:/srv/dest-a/restic/machine restore latest --target /rrestore"
        )
        machine.succeed("grep photo /rrestore/srv/media/p.jpg")
        machine.fail("test -e /rrestore/srv/media/x.tmp")
        machine.fail("test -e /rrestore/srv/media/index.db")
        machine.succeed(
            "sqlite3 /rrestore/var/lib/backup/staging/bulk-primary/dumps/media/index.db 'select v from i' "
            "| grep index-canary"
        )
        machine.succeed("test -f /var/lib/backup/bulk-primary.last-success")
        machine.fail("test -e /var/lib/backup/staging/bulk-primary")

    with subtest("bulk tier: a locked database dumps while its unit is stopped"):
        machine.succeed(
            "sqlite3 /rrestore/var/lib/backup/staging/bulk-primary/dumps/locked/l.db 'select v from t' "
            "| grep locked-canary"
        )
        machine.succeed("grep bulk-command-canary /rrestore/var/lib/backup/staging/bulk-primary/dumps/locked/command.dump")
        machine.succeed("systemctl is-active locker.service")

    with subtest("failure + staleness notifications"):
        machine.fail("systemctl start restic-backups-bulk-flaky.service")
        machine.wait_until_succeeds("grep 'restic-backups-bulk-flaky failed' /var/log/backup-notify")
        machine.succeed("systemctl start backup-freshness-check.service")
        machine.succeed("grep 'bulk-flaky: no successful run yet' /var/log/backup-notify")
        machine.fail("grep 'secure: no successful' /var/log/backup-notify")
        machine.fail("grep 'bulk-primary: no successful' /var/log/backup-notify")

    with subtest("external heartbeat pings"):
        # success pings (trailing newline in the key file must be stripped)
        machine.succeed("grep -x /test-ping-key/machine-backup-secure /var/log/hc-pings")
        machine.succeed("grep -x /test-ping-key/machine-backup-bulk-primary /var/log/hc-pings")
        # failure → /fail from the OnFailure unit; never a success ping
        machine.wait_until_succeeds("grep -x /test-ping-key/machine-backup-bulk-flaky/fail /var/log/hc-pings")
        machine.fail("grep -x /test-ping-key/machine-backup-bulk-flaky /var/log/hc-pings")

    with subtest("a failed dump or missing path leaves the other items in the bundle"):
        machine.succeed("rm -r /var/lib/backup/secure.last-success /srv/extra && sleep 1 && touch /run/break-dumps")
        machine.fail("systemctl start backup-secure.service")
        f = machine.succeed("ls /srv/dest-a/secure/machine/*-partial.tar.gz.age").strip()
        machine.succeed(f"mkdir /restore2 && age -d -i /etc/backup-test/age-key {f} | tar -xz -C /restore2")
        machine.succeed("grep pg-canary /restore2/dumps/app/postgres-host.sql")
        machine.fail("test -e /restore2/dumps/extra")
        machine.fail("test -e /restore2/srv/extra")
        machine.succeed("grep secret-file /restore2/srv/app/keep.pem")
        machine.fail("test -e /var/lib/backup/secure.last-success")
        machine.wait_until_succeeds("grep -x /test-ping-key/machine-backup-secure/fail /var/log/hc-pings")

    with subtest("bulk tier: a failed dump still backs up the rest, then fails the job"):
        machine.succeed("rm /var/lib/backup/bulk-primary.last-success")
        machine.fail("systemctl start restic-backups-bulk-primary.service")
        machine.succeed(
            "RESTIC_PASSWORD_FILE=/etc/backup-test/restic-pw RCLONE_CONFIG=/etc/backup-test/rclone.conf "
            "restic -r rclone:dest:/srv/dest-a/restic/machine restore latest --target /rrestore2"
        )
        machine.succeed(
            "sqlite3 /rrestore2/var/lib/backup/staging/bulk-primary/dumps/media/index.db 'select v from i' "
            "| grep index-canary"
        )
        machine.fail("test -e /rrestore2/var/lib/backup/staging/bulk-primary/dumps/locked")
        # No prune on an incomplete run: the complete snapshot from before stays.
        machine.succeed(f"[ $({snapshots} | jq length) -eq 2 ]")
        incomplete = machine.succeed(f"{snapshots} | jq -r '.[-1].id'").strip()
        machine.fail("test -e /var/lib/backup/bulk-primary.last-success")
        machine.fail("test -e /var/lib/backup/staging/bulk-primary")
        # The failed item still started its unit again.
        machine.wait_for_unit("locker.service")
        machine.wait_until_succeeds("grep 'restic-backups-bulk-primary failed' /var/log/backup-notify")

    with subtest("bulk tier: a complete run prunes again"):
        machine.succeed("rm /run/break-dumps")
        machine.succeed("systemctl start restic-backups-bulk-primary.service")
        # The incomplete snapshot goes; restic also keeps the oldest one while
        # the daily buckets aren't full.
        machine.succeed(f"[ $({snapshots} | jq length) -eq 2 ]")
        machine.fail(f"{snapshots} | jq -e --arg id {incomplete} 'any(.[]; .id == $id)'")
        machine.succeed("test -f /var/lib/backup/bulk-primary.last-success")
  '';
}
