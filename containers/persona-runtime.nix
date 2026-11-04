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

  # tool → binary in the container + the env var for its API key. Hosts only
  # name the `tool`, as in nix-config/personas.nix.
  toolSpecs = {
    gemini-cli = {
      binary = "/run/current-system/sw/bin/hermes";
      apiKeyEnvVar = "GEMINI_API_KEY";
    };
    claude-code = {
      binary = "/run/current-system/sw/bin/claude";
      apiKeyEnvVar = "ANTHROPIC_API_KEY";
    };
    # aider's litellm backend reads the plain ANTHROPIC_API_KEY too.
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

  # Ships with the module, so hosts need no repo checkout. It reads identity
  # files the host's sops-nix already decrypted; no sops or nix eval here.
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

      # The host data dir survives the ephemeral rootfs reset; wipe it so one
      # persona's state can't reach the next.
      find "$DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

      echo "Starting persona-runtime as $NAME..."
      # systemctl, not `machinectl start`: a declarative container has no
      # image under /var/lib/machines. machinectl works once it's running.
      systemctl start container@persona-runtime.service

      for _ in $(seq 1 20); do
        if machinectl show persona-runtime -p State 2>/dev/null | grep -q '^State=running'; then
          break
        fi
        sleep 0.5
      done

      # Source agent.env inside the container rather than `--setenv`, which
      # would put the API key in the host's process list.
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
  # One shared worker container for all personas (they never run at once), so
  # eval cost doesn't grow with their number. `persona-invoke <name>` rewrites
  # the bind-mounted identity files (agent.env, gitconfig, signing key), starts
  # the container, runs the tool and stops it again. The rootfs is ephemeral.
  # All personas share one egress profile.
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
      # Bind-mount sources must exist before the first persona-invoke run.
      {
        systemd.tmpfiles.rules = [
          "f ${cfg.secretsEnvFile} 0600 root root - -"
          "f ${cfg.gitConfigFile} 0644 root root - -"
          "f ${cfg.signingKeyFile} 0600 root root - -"
        ];

        # On the host: persona-invoke drives the container from outside.
        environment.systemPackages = [ personaInvokeScript ];
      }

      # ─── Host-side egress containment (mirrors openclaw.nix) ───
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

            # The model is always a runtime flag (`hermes -m <model>`), since
            # every persona shares this container.
            addToSystemPackages = true;

            environmentFiles = [ "/run/secrets/agent.env" ];

            settings = {
              # Upstream packaging gap (ModuleNotFoundError: hermes_state_common); unused.
              kanban.dispatch_in_gateway = false;
            };
          };

          # Other personas' tools (antigravity, self-hosted-runner) get added
          # when first used through this container.
          environment.systemPackages = [
            pkgs.claude-code
            pkgs.aider-chat
          ];

          # No programs.git: /etc/gitconfig is bind-mounted and rewritten per
          # persona by persona-invoke.

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
