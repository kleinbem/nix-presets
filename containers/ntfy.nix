{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.ntfy;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.ntfy = {
    enable = lib.mkEnableOption "ntfy pub/sub notification server container";
    ip = lib.mkOption { type = lib.types.str; };
    baseUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://ntfy.kleinbem.dev";
      description = "Public base URL clients use (behind caddy + Cloudflare tunnel).";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "256M";
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Host path to an env file (bind-mounted to /run/secrets/ntfy.env)
        that provisions ntfy's declarative users, ACLs and tokens:

          NTFY_AUTH_USERS=<user>:<bcrypt-hash>:user[,...]
          NTFY_AUTH_ACCESS=<user>:<topic>:read-only|write-only|read-write[,...]
          NTFY_AUTH_TOKENS=<user>:tk_<29 chars>[:label][,...]

        When set, the server runs with `auth-default-access = deny-all`:
        nothing is readable or publishable without a matching entry. When
        null (default), the server stays open — every topic readable and
        writable by anyone who can reach the vhost, which on the public
        tunnel means the whole internet. Topic-name secrecy is the only
        protection in that mode, and "alerts"-style default topic names
        are not secret at all.
      '';
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "ntfy";
    inherit cfg;
    # Bind-mounts to /run/secrets/ntfy.env — see factory.nix's secretsFile
    # doc comment.
    inherit (cfg) secretsFile;
    secretsFilePath = "/run/secrets/ntfy.env";
    innerConfig = {
      services.ntfy-sh = {
        enable = true;
        # Declarative users/ACLs/tokens arrive as NTFY_AUTH_* env vars from
        # the bind-mounted secrets file (ntfy reads every setting from env).
        environmentFile = lib.mkIf (cfg.secretsFile != null) "/run/secrets/ntfy.env";
        settings = {
          base-url = cfg.baseUrl;
          listen-http = ":2586";
          behind-proxy = true;
        }
        // lib.optionalAttrs (cfg.secretsFile != null) {
          # Auth DB lives in the ephemeral StateDirectory; that is fine
          # because every user/ACL/token is re-provisioned from the env
          # file on each start. Nothing stateful is kept in it.
          auth-file = "/var/lib/ntfy-sh/user.db";
          auth-default-access = "deny-all";
        }
        // {
          # Message cache is advisory only: the fleet-deploy signal has the
          # nightly autoUpgrade timer as its catch-up path, so losing cached
          # messages on container rebuild is harmless. Keep 12h for the web
          # UI and late long-poll reconnects.
          cache-duration = "12h";
          # Long-poll subscribers sit behind caddy + cloudflared; keepalives
          # below their idle timeouts stop silent connection drops.
          keepalive-interval = "45s";
        };
      };
      networking.firewall.allowedTCPPorts = [ 2586 ];
    };
  });
}
