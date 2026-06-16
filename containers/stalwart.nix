{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.stalwart;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };

  # Personas are the canonical source of mailboxes — see
  # nix-config/personas.nix. Each persona gets one mailbox at
  # <name>@<domain>, with mailbox display name from full-name.
  personas = import ../../nix-config/personas.nix;
  personaList = lib.attrValues personas;

  # The single domain all personas live on.
  defaultDomain = "kleinbem.dev";
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
    # Outbound relay credentials (AWS SES SMTP). Set via sops-templated
    # path so the credential file is materialised inside the container.
    relaySecretFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Path (inside container) to a file containing SMTP relay
        credentials for outbound mail. Format:
            username=<SES-SMTP-username>
            password=<SES-SMTP-password>
        Mount via sops-nix template — host should NOT carry plaintext.
      '';
    };
    adminPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path (inside container) to the admin account's password hash.";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "stalwart";
    inherit cfg;
    innerConfig = {
      services.stalwart-mail = {
        enable = true;
        package = pkgs.stalwart-mail;
        settings = {
          # Server listeners — submission (587, STARTTLS), IMAP (143, STARTTLS),
          # JMAP (8080 over HTTPS in production fronted by Caddy).
          server.hostname = "mail.${cfg.domain}";
          server.listener = {
            smtp = {
              bind = [ "[::]:25" ];
              protocol = "smtp";
            };
            submission = {
              bind = [ "[::]:587" ];
              protocol = "smtp";
              tls.implicit = false;
            };
            imap = {
              bind = [ "[::]:143" ];
              protocol = "imap";
              tls.implicit = false;
            };
            jmap = {
              bind = [ "[::]:8080" ];
              protocol = "jmap";
            };
          };

          # Outbound relay via AWS SES SMTP (or any reputable provider).
          # Stalwart itself never tries to send directly — its IP/reputation
          # would get spam-filtered. The relay's IP carries the reputation.
          queue.outbound.next-hop = lib.mkIf (cfg.relaySecretFile != null) "ses";
          remote.ses = lib.mkIf (cfg.relaySecretFile != null) {
            address = "email-smtp.eu-central-1.amazonaws.com";
            port = 587;
            tls.implicit = false;
            auth = {
              username = "%{file:${cfg.relaySecretFile}}%{env:USERNAME}";
              secret = "%{file:${cfg.relaySecretFile}}%{env:PASSWORD}";
            };
          };

          # Mailboxes — one per persona, materialised at container start
          # from personas.nix. To add the 6th persona, edit personas.nix —
          # the directive list below regenerates from it.
          directory.internal = {
            type = "memory";
            principals = lib.imap0
              (i: p: {
                name = p.email;
                description = p.full-name;
                class = "individual";
                # On first start, the user sets their own password via
                # the admin CLI; the manifest just declares existence.
              })
              personaList;
          };

          # DKIM signing — Stalwart generates per-domain keys at first
          # start and stores them under /var/lib/stalwart. The .pub key
          # needs to be published as a TXT record at:
          #   default._domainkey.${cfg.domain}
          # (post-Phase 1 task — generate, then add via Terraform).
          signature.dkim = {
            domain = [ cfg.domain ];
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
    };
  });
}
