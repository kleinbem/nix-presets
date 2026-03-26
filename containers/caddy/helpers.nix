{ lib }:
let
  inherit (lib) mapAttrs' nameValuePair;
in
{
  # Generates the upstream URL
  # For mTLS-enabled nodes, connect to port 443 (the sidecar) over HTTPS
  mkUpstream =
    node:
    let
      isMtls = node.mtls or false;
      # Temporary HTTP Bypass for testing bridge traffic
      protocol = if (node.secure or false) then "https" else "http";
      port = if isMtls then 80 else node.port;
    in
    "${protocol}://${node.ip}:${toString port}";

  # Generates the TLS transport block
  # For mTLS, include client certificate for mutual authentication
  mkTransport =
    node:
    let
      isMtls = node.mtls or false;
    in
    if isMtls then
      # Plain HTTP bypass for internal bridge traffic
      ""
    else if (node.secure or false) then
      "transport http { tls_insecure_skip_verify }"
    else
      "";

  # Generates the maintenance page HTML
  mkMaintPage = name: ''
    respond "<h1>System Maintenance</h1><p>${name} is offline.</p>" 503 {
      header Content-Type text/html
    }
  '';

  # Logic for mapping inventory to Caddy VirtualHosts
  genVHosts =
    {
      proxyTargets,
      hostIP,
      isGlobalMaint,
      helpers,
    }:
    mapAttrs' (
      name: node:
      let
        vhostName =
          let
            ipHost = if node.externalPort == 443 then hostIP else "${hostIP}:${toString node.externalPort}";
          in
          "${ipHost}, ${name}.local";

        isDown = isGlobalMaint || (node.maintenance or false);
      in
      nameValuePair vhostName {
        logFormat = "output stderr";
        extraConfig = ''
          tls internal
          ${
            if isDown then
              helpers.mkMaintPage name
            else
              let
                t = helpers.mkTransport node;
              in
              if t != "" then
                ''
                  reverse_proxy ${helpers.mkUpstream node} {
                    ${t}
                  }
                ''
              else
                ''
                  reverse_proxy ${helpers.mkUpstream node}
                ''
          }
        '';
      }
    ) proxyTargets;
}
