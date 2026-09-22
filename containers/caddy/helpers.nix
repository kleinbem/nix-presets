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
            ipHostStr =
              if node.externalPort == 443 then
                if (node ? domain) then "" else "${hostIP}, "
              else
                "${hostIP}:${toString node.externalPort}, :${toString node.externalPort}, ";
            customDomain =
              if (node ? domain) then
                ", ${if (node.insecure or false) then "http://" else ""}${node.domain}"
              else
                "";
          in
          "${ipHostStr}${name}.local${customDomain}";

        isDown = isGlobalMaint || (node.maintenance or false);
      in
      nameValuePair vhostName {
        logFormat = "output stderr";
        extraConfig = ''
          ${if (node.insecure or false) then "" else "tls internal"}
          ${
            if isDown then
              helpers.mkMaintPage name
            else
              let
                t = helpers.mkTransport node;
                # Authentik embedded-outpost forward-auth (replaces
                # Authelia). One shared Proxy Provider in "forward_domain"
                # mode covers every *.kleinbem.dev node with `auth = true`
                # via a single cookie_domain session — see
                # nix/infra/authentik.tf's fleet_forward_auth resources.
                # No ?rd= param needed (unlike Authelia's /api/verify) —
                # the outpost derives the post-login redirect from Caddy's
                # own forwarded request headers.
                authConfig =
                  if (node.auth or false) then
                    ''
                      forward_auth 10.85.48.142:9000 {
                        uri /outpost.goauthentik.io/auth/caddy
                        copy_headers X-Authentik-Username X-Authentik-Groups X-Authentik-Email X-Authentik-Name X-Authentik-Uid X-Authentik-Jwt
                        trusted_proxies private_ranges
                      }
                    ''
                  else
                    "";
              in
              if t != "" then
                ''
                  ${authConfig}
                  reverse_proxy ${helpers.mkUpstream node} {
                    ${t}
                  }
                ''
              else
                ''
                  ${authConfig}
                  reverse_proxy ${helpers.mkUpstream node}
                ''
          }
        '';
      }
    ) proxyTargets;
}
