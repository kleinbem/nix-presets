{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.stalwart;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };

  # The single domain all personas live on.
  defaultDomain = "kleinbem.dev";

  hasRelay = cfg.relaySecretFile != null;
  hasAdmin = cfg.adminPasswordFile != null;

  # NOTE: this preset does NOT declare mailboxes. Earlier revisions did
  # `import ../../nix-config/personas.nix` here and built a static
  # `directory.internal` principal list from `p.email` / `p.full-name` —
  # both broken: (1) nix-presets must not import back into nix-config
  # (see this repo's CLAUDE.md "Don't"), and the path doesn't exist when
  # nix-presets is a store-fetched flake input; (2) those fields live in
  # kleinbem-secrets/personas/contact.nix, not the public manifest.
  # Accounts are instead created imperatively by
  # nix-config/scripts/persona-scaffold.sh (step 6:
  # `stalwart-cli account create <email> <full-name>`). The internal
  # directory is persistent by default — the NixOS `services.stalwart`
  # module already sets `storage.data = "db"` (RocksDB under the data
  # dir), `directory.internal.type = "internal"`, `.store = "db"` and
  # `storage.directory = "internal"` as `mkDefault`s, so this preset only
  # needs listeners + admin + (optional) outbound relay.
in
{
  options.my.containers.stalwart = {
    enable = lib.mkEnableOption "Stalwart Mail Server Container";
    ip = lib.mkOption {
      type = lib.types.str;
      description = "Container IP on the cbr0 bridge.";
    };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      description = "Host directory bind-mounted to /var/lib/stalwart.";
    };
    domain = lib.mkOption {
      type = lib.types.str;
      default = defaultDomain;
      description = "Mail domain (MX target).";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "1G";
    };
    # Outbound relay credentials. HOST path (bind-mounted into the
    # container at /run/secrets/stalwart-relay). Point at a sops-nix
    # template so the host carries no plaintext.
    relaySecretFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Host path to a file containing SMTP relay credentials for
        outbound mail (KEY=VALUE lines: USERNAME=… / PASSWORD=…).
        null (default) = no relay, Stalwart sends directly (fine for
        mesh-internal persona↔persona mail; external delivery from a
        residential IP will be spam-filtered — see
        nix-config/docs/PHASE1_STALWART_STATUS.md).
      '';
    };
    adminPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Host path to a file holding the fallback-admin secret (a
        `mkpasswd -m sha-512` hash, or plaintext). Bind-mounted in and
        loaded via systemd LoadCredential. null = no fallback admin
        configured (you then rely on an account created out-of-band).
      '';
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "stalwart";
    inherit cfg;
    innerConfig = {
      services.stalwart = {
        enable = true;

        # Required (no module default). "26.05" ⇒ modern identity: data
        # dir /var/lib/stalwart, journal tracer, user/group `stalwart` —
        # matches the bind mount below. Do NOT lower this after first
        # start (it's a data-compat marker, like system.stateVersion).
        stateVersion = "26.05";

        # Fallback administrator — loaded via systemd LoadCredential (see
        # `credentials` below), referenced by macro. Lets `stalwart-cli`
        # authenticate to create persona accounts. TODO(phase1): confirm
        # `authentication.fallback-admin` is still the 0.15 key on first
        # deploy (it has been since ~0.9); the rest of this block is
        # straight off nixos/tests/stalwart/stalwart-config.nix.
        credentials = lib.mkIf hasAdmin {
          admin_secret = "/run/secrets/stalwart-admin-secret";
        };

        settings = {
          server.hostname = "mail.${cfg.domain}";

          # Plaintext-capable on the trusted cbr0 bridge; STARTTLS offered
          # opportunistically with Stalwart's self-signed cert. TODO: wire
          # a real cert (fleet step-ca / ACME) before any non-bridge
          # exposure.
          server.listener = {
            smtp = {
              bind = [ "[::]:25" ];
              protocol = "smtp";
            };
            submission = {
              bind = [ "[::]:587" ];
              protocol = "smtp";
            };
            imap = {
              bind = [ "[::]:143" ];
              protocol = "imap";
            };
            # HTTP surface: JMAP + the webadmin UI (module wires
            # webadmin.resource automatically when an http listener
            # exists). Reached directly on the container IP — not
            # Caddy-proxied.
            http = {
              bind = [ "[::]:8080" ];
              protocol = "http";
            };
          };

          session.auth.mechanisms = "[plain]";

          authentication.fallback-admin = lib.mkIf hasAdmin {
            user = "admin";
            secret = "%{file:/run/credentials/stalwart.service/admin_secret}%";
          };
        }
        // lib.optionalAttrs hasRelay {
          # Outbound relay (smart host). Only emitted when relaySecretFile
          # is set — otherwise Stalwart delivers directly (its built-in
          # default). v0.13+ uses "virtual queue" routing
          # (`queue.strategy.route` + `queue.route.<id>`); the old
          # `queue.*.next-hop` is now a build-time assertion failure.
          # TODO(phase1): validate this route shape against pkgs.stalwart
          # 0.15 once SES/relay creds actually exist.
          queue.strategy.route = "'relay'";
          queue.route.relay = {
            type = "relay";
            host = "email-smtp.eu-central-1.amazonaws.com";
            port = 587;
            protocol = "smtp";
            tls.implicit = false;
            auth.username = "%{file:/run/secrets/stalwart-relay}%{env:USERNAME}";
            auth.secret = "%{file:/run/secrets/stalwart-relay}%{env:PASSWORD}";
          };
        };
      };

      networking.firewall.allowedTCPPorts = [
        25
        143
        587
        8080
      ];
    };

    bindMounts = {
      "/var/lib/stalwart" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    }
    // lib.optionalAttrs hasAdmin {
      "/run/secrets/stalwart-admin-secret" = {
        hostPath = cfg.adminPasswordFile;
        isReadOnly = true;
      };
    }
    // lib.optionalAttrs hasRelay {
      "/run/secrets/stalwart-relay" = {
        hostPath = cfg.relaySecretFile;
        isReadOnly = true;
      };
    };
  });
}
