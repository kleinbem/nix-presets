# NixOS VM test for containers/dashboard/foyer: the container boots on a
# bridge, serves the SPA, answers /config.json from the host's bind mount and
# proxies the Gatus statuses.
#   nix build .#checks.x86_64-linux.dashboard-foyer
{ pkgs, module }:
let
  configFile = pkgs.writeText "foyer-config.json" (
    builtins.toJSON {
      title = "Test Foyer";
      hosts = [ ];
      services = [
        {
          id = "status";
          name = "Status";
          url = "https://status.example.com";
        }
      ];
    }
  );

  gatusRoot = pkgs.writeTextDir "api/v1/endpoints/statuses" (
    builtins.toJSON [
      {
        name = "Status";
        group = "Public";
        key = "public_status";
      }
    ]
  );
in
pkgs.testers.runNixOSTest {
  name = "dashboard-foyer";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ module ];

      options.my = {
        network.bridge = lib.mkOption { default = "br0"; };
        hardware.gpuRenderNode = lib.mkOption { default = null; };
      };

      config = {
        networking = {
          bridges.br0.interfaces = [ ];
          interfaces.br0.ipv4.addresses = [
            {
              address = "10.85.99.1";
              prefixLength = 24;
            }
          ];
          # The fake Gatus below.
          firewall.allowedTCPPorts = [ 8000 ];
        };

        # Stand-in for Gatus. Binding fails until br0 has its address.
        systemd.services.fake-gatus = {
          wantedBy = [ "multi-user.target" ];
          requires = [ "network-addresses-br0.service" ];
          after = [ "network-addresses-br0.service" ];
          serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8000 --bind 10.85.99.1 --directory ${gatusRoot}";
        };

        my.containers.dashboard = {
          enable = true;
          ip = "10.85.99.10/24";
          hostBridgeIp = "10.85.99.1";
          inherit configFile;
          gatusUrl = "http://10.85.99.1:8000";
        };
      };
    };

  testScript = ''
    machine.wait_for_unit("container@dashboard-foyer.service")
    machine.wait_until_succeeds("curl -sf http://10.85.99.10:8082/", timeout=120)

    with subtest("config.json comes from the host's bind mount"):
        machine.succeed(
            "curl -sf http://10.85.99.10:8082/config.json"
            " | ${pkgs.jq}/bin/jq -e '.title == \"Test Foyer\" and .services[0].id == \"status\"'"
        )

    with subtest("Gatus statuses are proxied on the same origin"):
        machine.wait_for_unit("fake-gatus.service")
        machine.succeed(
            "curl -sf http://10.85.99.10:8082/api/v1/endpoints/statuses"
            " | ${pkgs.jq}/bin/jq -e '.[0].key == \"public_status\"'"
        )

    with subtest("the SPA and its fallback are still served"):
        machine.succeed("curl -sf http://10.85.99.10:8082/ | grep -q sveltekit")
        machine.succeed("curl -sf http://10.85.99.10:8082/deep/spa/route | grep -q sveltekit")
  '';
}
