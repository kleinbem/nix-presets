# NixOS VM test for nixosModules/backup-engine: real backup AND restore of
# both tiers against a local rclone remote, plus the failure/staleness paths.
#   nix build .#checks.x86_64-linux.backup-engine
{ pkgs, module }:
let
  # TEST-ONLY keypair — generated for this VM test, protects nothing.
  agePub = "age1wrks5p2phce3znhnfj974frygk2dlpa69qw70wd7q4caljsm3c0s8rxzap";
  ageKey = "AGE-SECRET-KEY-1GFQZKXESH0R862VMN6ZY5WZMGRZ7U5ZCT2NQ3FEM8YCJP688PF4QTAG99C";

  fixtures = pkgs.writeShellScriptBin "setup-fixtures" ''
    set -euo pipefail
    mkdir -p /srv/app/cache /srv/media
    echo secret-file > /srv/app/keep.pem
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
      ];
      environment.etc = {
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
            command = "echo command-canary";
          };
          media = {
            tier = "bulk";
            paths = [ "/srv/media" ];
            exclude = [ "/srv/media/*.tmp" ];
            sqlite = [ "/srv/media/index.db" ];
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
        notify.command = toString (
          pkgs.writeShellScript "notify-to-file" ''
            echo "$@" >> /var/log/backup-notify
          ''
        );
      };
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("postgresql.service")
    machine.succeed("setup-fixtures")

    with subtest("secure tier: backup, decrypt, restore"):
        machine.succeed("systemctl start backup-secure.service")
        f = machine.succeed("ls /srv/dest-a/secure/machine/*.tar.gz.age").strip()
        machine.succeed(f"test -s {f}.sha256")
        machine.succeed(f"mkdir /restore && age -d -i /etc/backup-test/age-key {f} | tar -xz -C /restore")
        machine.succeed("sqlite3 /restore/dumps/app/app.db 'select v from t' | grep sqlite-canary")
        machine.succeed("grep pg-canary /restore/dumps/app/postgres-host.sql")
        machine.succeed("grep command-canary /restore/dumps/extra/command.dump")
        machine.succeed("grep secret-file /restore/srv/app/keep.pem")
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
        machine.succeed(
            "sqlite3 /rrestore/var/lib/backup/staging/bulk-primary/dumps/media/index.db 'select v from i' "
            "| grep index-canary"
        )
        machine.succeed("test -f /var/lib/backup/bulk-primary.last-success")
        machine.fail("test -e /var/lib/backup/staging/bulk-primary")

    with subtest("failure + staleness notifications"):
        machine.fail("systemctl start restic-backups-bulk-flaky.service")
        machine.wait_until_succeeds("grep 'restic-backups-bulk-flaky failed' /var/log/backup-notify")
        machine.succeed("systemctl start backup-freshness-check.service")
        machine.succeed("grep 'bulk-flaky: no successful run yet' /var/log/backup-notify")
        machine.fail("grep 'secure: no successful' /var/log/backup-notify")
        machine.fail("grep 'bulk-primary: no successful' /var/log/backup-notify")
  '';
}
