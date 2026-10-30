# NixOS VM test for containers/forgejo.nix: the container boots on a bridge,
# Forgejo serves HTTP, and the bootstrap creates the admin and the Authentik
# login source exactly once, also on a rerun.
#   nix build .#checks.x86_64-linux.forgejo
{ pkgs, module }:
let
  issuer = "http://10.85.99.1:8000";
  oidcRoot = pkgs.writeTextDir ".well-known/openid-configuration" (
    builtins.toJSON {
      inherit issuer;
      authorization_endpoint = "${issuer}/authorize";
      token_endpoint = "${issuer}/token";
      userinfo_endpoint = "${issuer}/userinfo";
      jwks_uri = "${issuer}/jwks";
      response_types_supported = [ "code" ];
      subject_types_supported = [ "public" ];
      id_token_signing_alg_values_supported = [ "RS256" ];
    }
  );
in
pkgs.testers.runNixOSTest {
  name = "forgejo";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ module ];

      options.my = {
        network.bridge = lib.mkOption { default = "br0"; };
        hardware.gpuRenderNode = lib.mkOption { default = null; };
      };

      config = {
        # Forgejo and Postgres run inside the container in this guest.
        virtualisation.memorySize = 2048;

        networking = {
          bridges.br0.interfaces = [ ];
          interfaces.br0.ipv4.addresses = [
            {
              address = "10.85.99.1";
              prefixLength = 24;
            }
          ];
          # The fake OIDC endpoint below.
          firewall.allowedTCPPorts = [ 8000 ];
        };

        # TEST-ONLY secrets, protect nothing.
        environment.etc = {
          "forgejo-test/admin-password".text = "test-admin-password-1";
          "forgejo-test/oidc-secret".text = "test-oidc-secret";
        };

        # Stand-in for Authentik: add-oauth fetches the discovery document.
        systemd.services.fake-oidc = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8000 --bind 10.85.99.1 --directory ${oidcRoot}";
        };

        my.containers.forgejo = {
          enable = true;
          ip = "10.85.99.10/24";
          hostDataDir = "/var/lib/images/forgejo";
          admin.passwordFile = "/etc/forgejo-test/admin-password";
          oidc = {
            enable = true;
            issuerUrl = "http://10.85.99.1:8000/.well-known/openid-configuration";
            clientSecretFile = "/etc/forgejo-test/oidc-secret";
          };
        };
      };
    };

  testScript = ''
    from datetime import timedelta

    def inside(cmd):
        return machine.succeed(f"nixos-container run forgejo -- {cmd}")

    def forgejo(args):
        return inside(
            "bash -c 'cd /var/lib/forgejo && runuser -u forgejo -- env FORGEJO_WORK_DIR=/var/lib/forgejo "
            f"FORGEJO_CUSTOM=/var/lib/forgejo/custom forgejo --work-path /var/lib/forgejo {args} 2>&1'"
        )

    machine.wait_for_unit("container@forgejo.service")
    machine.wait_until_succeeds(
        "curl -sf http://10.85.99.10:3000/api/healthz", timeout=timedelta(minutes=5)
    )
    try:
        machine.wait_until_succeeds(
            "nixos-container run forgejo -- systemctl show -p ActiveState,Result forgejo-bootstrap.service"
            " | tr '\\n' ' ' | grep -q 'Result=success ActiveState=inactive\\|ActiveState=inactive Result=success'",
            timeout=timedelta(minutes=2),
        )
    finally:
        print(machine.execute("nixos-container run forgejo -- systemctl status --no-pager forgejo-bootstrap.service forgejo.service")[1])
        print(machine.execute("nixos-container run forgejo -- journalctl --no-pager -u forgejo-bootstrap.service")[1])

    with subtest("admin and login source exist"):
        assert "martin" in forgejo("admin user list --admin")
        assert "authentik" in forgejo("admin auth list")

    with subtest("bootstrap rerun is idempotent"):
        inside("systemctl restart forgejo-bootstrap.service")
        names = [l.split()[1] for l in forgejo("admin auth list").splitlines()[1:] if l.strip()]
        assert names.count("authentik") == 1, names
        users = [l.split()[1] for l in forgejo("admin user list --admin").splitlines()[1:] if l.strip()]
        assert users.count("martin") == 1, users

    with subtest("admin can use the API with its password"):
        machine.succeed(
            "curl -sf -u martin:test-admin-password-1 http://10.85.99.10:3000/api/v1/user | grep -q '\"login\":\"martin\"'"
        )

    with subtest("no open sign-up"):
        machine.fail("curl -sf http://10.85.99.10:3000/user/sign_up | grep -q 'name=\"user_name\"'")

    with subtest("state is on the host bind mount"):
        machine.succeed("test -d /var/lib/images/forgejo/repositories")
        machine.succeed("test -n \"$(ls -A /var/lib/images/forgejo/postgresql)\"")
  '';
}
