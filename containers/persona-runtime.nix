{ self, inputs }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.persona-runtime;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };

  # tool → {binary inside the container, env var its API key needs to land
  # in}. This is internal knowledge of what this container's own package
  # set provides — the consumer host just says which `tool` a persona
  # uses (same field name as nix-config/personas.nix's own `tool`), it
  # doesn't need to know container-internal paths.
  toolSpecs = {
    gemini-cli = {
      binary = "/run/current-system/sw/bin/hermes";
      apiKeyEnvVar = "GEMINI_API_KEY";
    };
    claude-code = {
      binary = "/run/current-system/sw/bin/claude";
      apiKeyEnvVar = "ANTHROPIC_API_KEY";
    };
    # aider reads ANTHROPIC_API_KEY via its litellm backend the same way
    # claude-code does (its own --anthropic-api-key flag maps to the more
    # specific AIDER_ANTHROPIC_API_KEY, but the plain var works too and
    # keeps this entry consistent with claude-code's).
    aider = {
      binary = "/run/current-system/sw/bin/aider";
      apiKeyEnvVar = "ANTHROPIC_API_KEY";
    };
  };

  personasManifest = pkgs.writeText "persona-runtime-personas.json" (
    builtins.toJSON (
      lib.mapAttrs (
        name: p:
        (toolSpecs.${p.tool}
          or (throw "persona-runtime: persona '${name}' has unwired tool '${p.tool}' — add it to toolSpecs and this container's environment.systemPackages first")
        )
        // {
          inherit (p)
            signingKeyPath
            apiKeyPath
            fullName
            email
            ;
        }
      ) cfg.personas
    )
  );

  # Packaged here (not left as a standalone repo script) so it ships with
  # the container closure on any host that enables this module — no manual
  # file copy, no live git checkout of nix-config/kleinbem-secrets needed
  # on the target host. Identity material is read straight from paths
  # sops-nix already decrypted at activation time (the host's own
  # sops.secrets.*, wired up by the consumer host's config) — this script
  # never shells out to sops or nix eval itself.
  personaInvokeScript = pkgs.writeShellApplication {
    name = "persona-invoke";
    runtimeInputs = [
      pkgs.jq
      pkgs.systemd
      pkgs.coreutils
    ];
    text = ''
      MANIFEST=${personasManifest}
      DATA_DIR=${lib.escapeShellArg cfg.hostDataDir}

      if [[ $EUID -ne 0 ]]; then
        echo "Must run as root — machinectl start/stop, and writes root:root identity files." >&2
        exit 1
      fi
      if [[ $# -lt 1 ]]; then
        echo "Usage: persona-invoke <persona-name> [args passed straight to the persona's tool]" >&2
        echo "Available personas: $(jq -r 'keys | join(", ")' "$MANIFEST")" >&2
        exit 1
      fi
      NAME=$1
      shift

      if ! jq -e --arg n "$NAME" 'has($n)' "$MANIFEST" >/dev/null; then
        echo "'$NAME' isn't wired into persona-runtime yet." >&2
        echo "Available: $(jq -r 'keys | join(", ")' "$MANIFEST")" >&2
        exit 1
      fi

      SIGNING_KEY_PATH=$(jq -r --arg n "$NAME" '.[$n].signingKeyPath' "$MANIFEST")
      API_KEY_PATH=$(jq -r --arg n "$NAME" '.[$n].apiKeyPath // empty' "$MANIFEST")
      FULLNAME=$(jq -r --arg n "$NAME" '.[$n].fullName' "$MANIFEST")
      EMAIL=$(jq -r --arg n "$NAME" '.[$n].email' "$MANIFEST")
      BINARY=$(jq -r --arg n "$NAME" '.[$n].binary' "$MANIFEST")
      API_KEY_ENV_VAR=$(jq -r --arg n "$NAME" '.[$n].apiKeyEnvVar' "$MANIFEST")

      echo "Invoking $NAME via persona-runtime..."

      umask 077
      install -m 600 "$SIGNING_KEY_PATH" ${lib.escapeShellArg cfg.signingKeyFile}

      cat >${lib.escapeShellArg cfg.gitConfigFile} <<EOF
      [user]
      	name = $FULLNAME
      	email = $EMAIL
      	signingkey = /run/secrets/signing-key
      [commit]
      	gpgsign = true
      [gpg]
      	format = ssh
      EOF
      chmod 644 ${lib.escapeShellArg cfg.gitConfigFile}

      if [[ -n "''${API_KEY_PATH:-}" && -f "$API_KEY_PATH" ]]; then
        printf '%s=%s\n' "$API_KEY_ENV_VAR" "$(cat "$API_KEY_PATH")" >${lib.escapeShellArg cfg.secretsEnvFile}
      else
        : >${lib.escapeShellArg cfg.secretsEnvFile}
      fi
      chmod 600 ${lib.escapeShellArg cfg.secretsEnvFile}

      # Clean slate — a host-side bind mount survives the container's own
      # ephemeral rootfs reset, so without this, one persona's session
      # state could bleed into the next persona's context.
      find "$DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

      echo "Starting persona-runtime as $NAME..."
      # autoStart = false means this is a declarative NixOS container that
      # has never been booted yet — nothing is registered with
      # systemd-machined for `machinectl start` to boot (that verb wants a
      # pre-existing image under /var/lib/machines, which doesn't exist for
      # an ephemeral container until its own systemd unit runs it). The
      # unit NixOS actually generates is container@persona-runtime.service
      # — go through systemctl, same as any other declarative container
      # that isn't autoStart'd. `machinectl shell`/`machinectl poweroff`
      # below still work fine once it's running, machined discovers it then.
      systemctl start container@persona-runtime.service

      for _ in $(seq 1 20); do
        if machinectl show persona-runtime -p State 2>/dev/null | grep -q '^State=running'; then
          break
        fi
        sleep 0.5
      done

      # Source agent.env inside the container before exec'ing the tool,
      # rather than passing the API key via `machinectl shell --setenv`
      # (would put the secret in the host's own argv/process list). Works
      # uniformly for every tool — hermes-agent also reads GEMINI_API_KEY
      # from its own $HERMES_HOME/.env (copied from this same file at
      # container activation), so sourcing it again here is redundant but
      # harmless for that tool specifically.
      set +e
      # shellcheck disable=SC2016  # single-quoted on purpose — this runs
      # INSIDE the container via `sh -c`, must not expand here.
      machinectl shell \
        --setenv=HOME=/var/lib/hermes \
        --setenv=HERMES_HOME=/var/lib/hermes/.hermes \
        persona-runtime /run/current-system/sw/bin/bash -c \
        'set -a; [ -f /run/secrets/agent.env ] && . /run/secrets/agent.env; set +a; exec "$0" "$@"' \
        "$BINARY" "$@"
      RESULT=$?
      set -e

      echo "Stopping persona-runtime..."
      systemctl stop container@persona-runtime.service 2>/dev/null || true

      exit "$RESULT"
    '';
  };
in
{
  # Generic, persona-agnostic worker container — ONE declared instance,
  # identity swapped at invocation time instead of one container per
  # persona (hermes-juan.nix's shape). Built 2026-08-08 once "up to ~200
  # personas, never running concurrently" made per-persona standing
  # containers the wrong model: this way NixOS eval/deploy cost is O(1)
  # regardless of how many personas exist, not O(n).
  #
  # How identity gets in: NOTHING persona-specific is a Nix option here
  # EXCEPT `personas` (below), which is plain data — signing-key/API-key
  # paths the consumer host already decrypted via its own sops.secrets,
  # plus git name/email. secretsEnvFile / gitConfigFile / signingKeyFile
  # are bind-mounted at FIXED container paths; their HOST-SIDE content
  # gets rewritten by the packaged `persona-invoke <name>` command (built
  # below as personaInvokeScript, shipped via environment.systemPackages —
  # no separate script checkout needed on the host) immediately before
  # each `machinectl start`, and the model is passed as a `hermes -m ...`
  # runtime flag, not a NixOS config value (confirmed working live
  # 2026-08-08 testing juan's standing container). autoStart = false — the
  # invoke script starts/stops it per call. ephemeral = true (mkContainer's
  # default) means the rootfs resets on every start, so no persona's
  # session state leaks into the next invocation.
  #
  # Rights/egress tiers per persona (role-tags → different egress
  # profiles) are NOT built yet — this first version ships one
  # restrictLan-only profile shared by everyone, same as juan's original
  # container. Revisit once more than one tier is actually needed.
  options.my.containers.persona-runtime = {
    enable = lib.mkEnableOption "Generic persona-agnostic agent worker container";
    ip = lib.mkOption { type = lib.types.str; };
    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Started on-demand by the invoke script, not at host boot.";
    };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      description = "Scratch state dir. ephemeral=true wipes the container rootfs each start regardless, but this survives host reboots between invocations — not meant to carry one persona's state into the next.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "4G";
    };
    secretsEnvFile = lib.mkOption {
      type = lib.types.str;
      description = "Fixed HOST path bind-mounted to /run/secrets/agent.env — one KEY=VALUE line (env var name depends on the invoked persona's tool, e.g. GEMINI_API_KEY or ANTHROPIC_API_KEY). Content rewritten per invocation by persona-invoke — not persona-specific at the Nix level.";
    };
    gitConfigFile = lib.mkOption {
      type = lib.types.str;
      description = "Fixed HOST path bind-mounted to /etc/gitconfig. Content (user.name/email/signingkey/gpg.format/commit.gpgsign) rewritten per invocation.";
    };
    signingKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "Fixed HOST path bind-mounted to the container path gitConfigFile's user.signingkey points at (/run/secrets/signing-key). Content rewritten per invocation.";
    };
    egress = {
      restrictLan = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Block agent-initiated connections into private address space —
          same rationale as openclaw/hermes-juan: an autonomous agent with
          shell + git access must not be able to pivot into the LAN.
        '';
      };
      lanAllowlist = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
    };
    personas = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            tool = lib.mkOption {
              type = lib.types.enum (builtins.attrNames toolSpecs);
              description = "Which of this container's built-in tools to run this persona through — same value as nix-config/personas.nix's own `tool` field. Resolves to a binary path + API-key env var via this module's toolSpecs, not something the consumer host needs to know.";
            };
            signingKeyPath = lib.mkOption {
              type = lib.types.str;
              description = "Host path to this persona's DECRYPTED ed25519 signing key — the consumer host declares this via its own sops.secrets, e.g. config.sops.secrets.persona_<name>_signing_key.path. Not decrypted by this module.";
            };
            apiKeyPath = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Host path to this persona's DECRYPTED API key (e.g. Gemini), if it has one.";
            };
            fullName = lib.mkOption {
              type = lib.types.str;
              description = "Git commit author name for this persona.";
            };
            email = lib.mkOption {
              type = lib.types.str;
              description = "Git commit author email for this persona.";
            };
          };
        }
      );
      default = { };
      description = ''
        Every persona invocable through this shared runtime, keyed by
        name. This is a plain data option — nix-presets doesn't import
        nix-config's personas.nix (presets must not depend back on the
        consumer, see this repo's CLAUDE.md); the consumer host builds
        this attrset from its own personas.nix + sops.secrets and passes
        it in. persona-invoke reads it via a generated JSON manifest, not
        by any live nix eval — the script has zero nix-config/
        kleinbem-secrets checkout dependency.
      '';
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # Bind-mount source files must exist before the container's systemd
      # mount units can attach to them, even before persona-invoke.sh has
      # ever run — empty placeholders, real content comes from the first
      # invocation.
      {
        systemd.tmpfiles.rules = [
          "f ${cfg.secretsEnvFile} 0600 root root - -"
          "f ${cfg.gitConfigFile} 0644 root root - -"
          "f ${cfg.signingKeyFile} 0600 root root - -"
        ];

        # Host-level (not innerConfig) — persona-invoke runs on the HOST to
        # drive machinectl, it doesn't run inside the persona-runtime
        # container itself.
        environment.systemPackages = [ personaInvokeScript ];
      }

      # ─── Host-side egress containment (mirrors openclaw.nix/hermes-juan.nix) ───
      (lib.mkIf cfg.egress.restrictLan (
        let
          containerIp = lib.head (lib.splitString "/" cfg.ip);
          allowRules = lib.concatMapStringsSep "\n        " (
            dst: "ip saddr ${containerIp} ip daddr ${dst} accept"
          ) cfg.egress.lanAllowlist;
        in
        {
          networking.nftables.tables.zt-persona-runtime-egress = {
            family = "inet";
            content = ''
              chain forward {
                type filter hook forward priority filter; policy accept;
                ip saddr ${containerIp} ct state { established, related } accept
                ${allowRules}
                ip saddr ${containerIp} ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } limit rate 6/minute log prefix "zt-persona-runtime-egress drop: "
                ip saddr ${containerIp} ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } counter drop
              }
            '';
          };
        }
      ))

      (mkContainer {
        inherit config;
        name = "persona-runtime";
        inherit cfg;
        innerConfig = {
          imports = [ inputs.hermes.nixosModules.default ];

          networking.nameservers = lib.mkForce [
            "1.1.1.1"
            "8.8.8.8"
          ];

          services.hermes-agent = {
            enable = true;
            package = inputs.hermes.packages.${pkgs.stdenv.hostPlatform.system}.messaging;

            # Runnable via `machinectl shell persona-runtime
            # /run/current-system/sw/bin/hermes -m <model> -z '...'` — model
            # is always a runtime flag here, never a Nix value, since this
            # container is shared across every persona.
            addToSystemPackages = true;

            environmentFiles = [ "/run/secrets/agent.env" ];

            settings = {
              # Same upstream packaging gap as hermes.nix/hermes-juan.nix —
              # ModuleNotFoundError: hermes_state_common. Not used anyway.
              kanban.dispatch_in_gateway = false;
            };
          };

          # Other personas' declared tools (antigravity, self-hosted-runner —
          # see nix-config/personas.nix's `tool` field per persona) get
          # added here as they're actually invoked through this container,
          # not preemptively for all of them. ANTHROPIC_API_KEY (claude-code,
          # aider) reads straight from the process environment, no
          # dotenv-from-home convention like hermes-agent's — see
          # persona-invoke's `machinectl shell ... bash -c 'source agent.env'`
          # wrapper above, which is what actually gets it there.
          environment.systemPackages = [
            pkgs.claude-code
            pkgs.aider-chat
          ];

          # NOT programs.git — that bakes a static /etc/gitconfig at build
          # time, which defeats the point (one shared container, N
          # personas). /etc/gitconfig is bind-mounted directly instead
          # (see bindMounts below); persona-invoke.sh writes real
          # user.name/email/signingkey content into it before each start.

          networking.firewall.enable = true;
        };
        bindMounts = {
          "/run/secrets/agent.env" = {
            hostPath = cfg.secretsEnvFile;
            isReadOnly = true;
          };
          "/etc/gitconfig" = {
            hostPath = cfg.gitConfigFile;
            isReadOnly = true;
          };
          "/run/secrets/signing-key" = {
            hostPath = cfg.signingKeyFile;
            isReadOnly = true;
          };
          "/var/lib/hermes" = {
            hostPath = cfg.hostDataDir;
            isReadOnly = false;
          };
        };
      })
    ]
  );
}
