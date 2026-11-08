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

  # `tls internal` (the fleet CA) unless `publicCert = true`, for clients that
  # trust only public CAs. That gets Let's Encrypt via Cloudflare DNS-01, so a
  # mesh-only name needn't be reachable from the internet. Public resolvers for
  # the propagation check, since NetBird answers the node's own name on the mesh.
  mkTls =
    node:
    if node.insecure or false then
      ""
    else if node.publicCert or false then
      ''
        tls {
          dns cloudflare {env.CLOUDFLARE_API_TOKEN}
          resolvers 1.1.1.1 1.0.0.1
        }
      ''
    else
      "tls internal";

  # Extra path routes to other ports on the node's own ip, e.g. Buzz's
  # pairing relay: `extraRoutes."/pair*" = 3001;`. Each gets its own handle
  # block ahead of the node's main reverse_proxy.
  mkExtraRoutes =
    node:
    lib.concatStrings (
      lib.mapAttrsToList (path: port: ''
        handle ${path} {
          reverse_proxy http://${node.ip}:${toString port}
        }
      '') (node.extraRoutes or { })
    );

  # Generates the maintenance page HTML
  mkMaintPage = name: ''
    respond "<h1>System Maintenance</h1><p>${name} is offline.</p>" 503 {
      header Content-Type text/html
    }
  '';

  # SPA frontend serving static assets with fallback and reverse proxy for backend routes
  mkSpa =
    {
      node,
      authUpstream ? null,
      helpers,
    }:
    if node ? spa then
      let
        backendPaths = node.spa.backendPaths or [ ];
        pathsStr = lib.concatStringsSep " " backendPaths;
        corsHeader =
          if (node.cors or true) then
            ''
              header Access-Control-Allow-Origin *
              header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS, HEAD"
              header Access-Control-Allow-Headers "Authorization, Content-Type, Origin, Accept"
            ''
          else
            "";
        upstream = helpers.mkUpstream node;
        authConfig =
          if (node.auth or false) && authUpstream != null then
            ''
              forward_auth ${authUpstream} {
                uri /outpost.goauthentik.io/auth/caddy
                copy_headers X-Authentik-Username X-Authentik-Groups X-Authentik-Email X-Authentik-Name X-Authentik-Uid X-Authentik-Jwt
                trusted_proxies private_ranges
              }
            ''
          else
            "";
      in
      ''
        @cors_preflight method OPTIONS
        handle @cors_preflight {
          ${corsHeader}
          respond 204
        }
        ${lib.optionalString (backendPaths != [ ]) ''
          @spa_backend path ${pathsStr}
          handle @spa_backend {
            ${corsHeader}
            ${authConfig}
            reverse_proxy ${upstream}
          }
        ''}
        handle {
          ${authConfig}
          root * ${node.spa.root}
          try_files {path} {path}/ /200.html
          file_server
        }
      ''
    else
      null;

  # Logic for mapping inventory to Caddy VirtualHosts
  genVHosts =
    {
      proxyTargets,
      hostIP,
      authUpstream ? null,
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
            # `extraDomains`: more names for the same site, e.g. the old name
            # while a node is renamed.
            domains = lib.optional (node ? domain) node.domain ++ node.extraDomains or [ ];
            scheme = if (node.insecure or false) then "http://" else "";
            customDomain = lib.concatMapStrings (d: ", ${scheme}${d}") domains;
          in
          # A publicCert node serves only its domains: ACME can't issue for
          # the `.local` or IP aliases, and they'd share the site's issuer.
          if node.publicCert or false then
            lib.concatStringsSep ", " domains
          else
            "${ipHostStr}${name}.local${customDomain}";

        isDown = isGlobalMaint || (node.maintenance or false);
        spaBlock = helpers.mkSpa { inherit node authUpstream helpers; };
      in
      nameValuePair vhostName {
        logFormat = "output stderr";
        extraConfig = ''
          ${helpers.mkTls node}
          ${
            if isDown then
              helpers.mkMaintPage name
            else if spaBlock != null then
              helpers.mkExtraRoutes node + spaBlock
            else
              let
                t = helpers.mkTransport node;
                upstream = helpers.mkUpstream node;
                reverseProxyBlock =
                  if t != "" then
                    ''
                      reverse_proxy ${upstream} {
                        ${t}
                      }
                    ''
                  else
                    "reverse_proxy ${upstream}";
                # Authentik embedded-outpost forward-auth. One "forward_domain"
                # Proxy Provider (nix/infra/authentik.tf) covers every *.kleinbem.dev
                # node with `auth = true` via one cookie_domain session, so .local
                # aliases aren't covered. The outpost derives the post-login redirect.
                authConfig = ''
                  forward_auth ${authUpstream} {
                    uri /outpost.goauthentik.io/auth/caddy
                    copy_headers X-Authentik-Username X-Authentik-Groups X-Authentik-Email X-Authentik-Name X-Authentik-Uid X-Authentik-Jwt
                    trusted_proxies private_ranges
                  }
                '';
                # Paths that skip forward_auth, for callers that can't log in
                # (e.g. n8n webhooks). They get no auth here at all, so the app
                # must authenticate them itself.
                authExcludePaths = node.authExcludePaths or [ ];
              in
              helpers.mkExtraRoutes node
              + (
                if !(node.auth or false) then
                  reverseProxyBlock
                else if authExcludePaths != [ ] then
                  ''
                    @auth_excluded path ${lib.concatStringsSep " " authExcludePaths}
                    handle @auth_excluded {
                      ${reverseProxyBlock}
                    }
                    handle {
                      ${authConfig}
                      ${reverseProxyBlock}
                    }
                  ''
                else
                  ''
                    ${authConfig}
                    ${reverseProxyBlock}
                  ''
              )
          }
        '';
      }
    ) proxyTargets;
}
