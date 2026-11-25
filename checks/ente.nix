# NixOS VM test for containers/ente.nix on Garage: the container boots,
# Garage gets its layout, bucket and key, museum answers /ping, museum keeps
# retrying while Postgres refuses it, and Postgres' files survive a host
# tmpfiles run plus a container restart.
#   nix build .#checks.x86_64-linux.ente
{ pkgs, module }:
pkgs.testers.runNixOSTest {
  name = "ente";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ module ];

      options.my = {
        network.bridge = lib.mkOption { default = "br0"; };
        hardware.gpuRenderNode = lib.mkOption { default = null; };
      };

      config = {
        virtualisation = {
          memorySize = 3072;
          cores = 2;
        };

        networking = {
          bridges.br0.interfaces = [ ];
          interfaces.br0.ipv4.addresses = [
            {
              address = "10.85.99.1";
              prefixLength = 24;
            }
          ];
        };

        # TEST-ONLY secrets, protect nothing.
        environment.etc = {
          "ente-test/rpc-secret".text = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
          "ente-test/key-id".text = "GK0123456789abcdef01234567";
          "ente-test/secret".text = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";
          "ente-test/jwt".text = "eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHg=";
          "ente-test/key-encryption".text = "enp6enp6enp6enp6enp6enp6enp6enp6enp6enp6eno=";
          "ente-test/key-hash".text =
            "eXl5eXl5eXl5eXl5eXl5eXl5eXl5eXl5eXl5eXl5eXl5eXl5eXl5eXl5eXl5eXl5eXl5eXl5eXl5eXl5eXl5eQ==";
        };

        my.containers.ente = {
          enable = true;
          ip = "10.85.99.20/24";
          hostDataDir = "/var/lib/images/ente";
          domain = "2fa.example.test";
          jwtSecretFile = "/etc/ente-test/jwt";
          keyEncryptionFile = "/etc/ente-test/key-encryption";
          keyHashFile = "/etc/ente-test/key-hash";
          minio.enable = false;
          garage = {
            enable = true;
            rpcSecretFile = "/etc/ente-test/rpc-secret";
          };
          s3 = {
            backend = "garage";
            accessKeyIdFile = "/etc/ente-test/key-id";
            secretAccessKeyFile = "/etc/ente-test/secret";
          };
        };

        # The web app's image can't be pulled without a network.
        containers.ente.config =
          { lib, ... }:
          {
            systemd.services.podman-web.enable = lib.mkForce false;
          };
      };
    };

  testScript = ''
    from datetime import timedelta

    def inside(cmd):
        return machine.succeed(f"nixos-container run ente -- {cmd}")

    def garage(args):
        return inside(f"bash -c 'set -a; . /run/garage.env; garage {args}'")

    def show(unit, prop):
        return inside(f"systemctl show -P {prop} {unit}").strip()

    def ping():
        machine.wait_until_succeeds(
            "curl -sf -o /dev/null -w '%{http_code}' http://10.85.99.20:8080/ping | grep -qx 200",
            timeout=timedelta(minutes=5),
        )

    def dump():
        print(machine.execute(
            "nixos-container run ente -- systemctl status --no-pager --lines=0 "
            "garage ente-garage-setup ente-env-setup ente postgresql"
        )[1])
        print(machine.execute(
            "nixos-container run ente -- journalctl --no-pager -b -o short-monotonic "
            "-u garage -u ente-garage-setup -u ente -u postgresql -u systemd-tmpfiles-setup | tail -n 150"
        )[1])
        print(machine.execute("ls -lan /var/lib/images/ente /var/lib/images/ente/garage /var/lib/images/ente/postgresql")[1])

    def pg_files_owned_by_postgres():
        # postgres is uid 71 in the container and, with privateUsers = no, on the host.
        # The first find fails the check on a missing or empty data dir.
        out = machine.succeed(
            "find /var/lib/images/ente/postgresql/17/global -uid 71 -name pg_control | grep -q . && "
            "find /var/lib/images/ente/postgresql -mindepth 1 ! -uid 71 -printf '%u:%g %p\\n' | head -n 20"
        )
        assert out.strip() == "", f"Postgres files not owned by postgres:\n{out}"

    def no_pg_permission_errors():
        out = inside("journalctl --no-pager -b -u postgresql -u ente")
        assert "Permission denied" not in out, out

    machine.wait_for_unit("container@ente.service")

    try:
        with subtest("garage runs and ente-garage-setup created the bucket and key"):
            machine.wait_until_succeeds(
                "nixos-container run ente -- systemctl is-active garage.service",
                timeout=timedelta(minutes=3),
            )
            machine.wait_until_succeeds(
                "nixos-container run ente -- systemctl show -P Result ente-garage-setup.service | grep -qx success"
                " && nixos-container run ente -- systemctl is-active ente-garage-setup.service",
                timeout=timedelta(minutes=3),
            )
            garage("bucket info ente")
            assert "ente-key" in garage("key info GK0123456789abcdef01234567")

        with subtest("museum answers /ping from the host"):
            ping()

        with subtest("museum didn't take Postgres' files"):
            pg_files_owned_by_postgres()
            no_pg_permission_errors()

        with subtest("museum keeps retrying while Postgres refuses it"):
            inside("runuser -u postgres -- psql -c 'ALTER ROLE ente NOLOGIN'")
            env_before = inside("stat -c %.9Y /run/ente.env")
            inside("systemctl restart ente.service")
            # A museum restart rebuilds the env file, so rotated secrets apply.
            assert inside("stat -c %.9Y /run/ente.env") != env_before
            machine.wait_until_succeeds(
                "test $(nixos-container run ente -- systemctl show -P NRestarts ente.service) -ge 6",
                timeout=timedelta(minutes=5),
            )
            assert show("ente.service", "Result") != "start-limit-hit"
            inside("runuser -u postgres -- psql -c 'ALTER ROLE ente LOGIN'")
            ping()
            assert show("ente-env-setup.service", "Result") == "success"

        with subtest("host tmpfiles run plus container restart keeps Postgres readable"):
            # What every host switch does before a container update restarts it.
            machine.succeed("systemd-tmpfiles --create")
            machine.succeed("systemctl restart container@ente.service")
            machine.wait_for_unit("container@ente.service")
            ping()
            # museum connects right after start; give a bad chown time to bite.
            machine.sleep(15)
            ping()
            pg_files_owned_by_postgres()
            no_pg_permission_errors()
    finally:
        dump()
  '';
}
