{ self, inputs }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.openclaw;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.openclaw = {
    enable = lib.mkEnableOption "OpenClaw Personal AI Agent Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    vllmUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Internal URL to the local vLLM/OpenAI instance";
    };
    ollamaUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Internal URL to the local Ollama instance";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "4G";
    };
    enableAudio = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable /dev/snd ALSA hardware pass-through for ambient listening & TTS.";
    };
    enableVideo = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable /dev/video* hardware pass-through for ambient visual perception.";
    };
    enableUSB = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable /dev/bus/usb hardware pass-through for TPU accelerators and Home Automation devices.";
    };
    egress = {
      restrictLan = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Block openclaw-initiated connections into private address space
          (LAN, NetBird mesh, link-local) at the HOST's forward chain.
          openclaw parses untrusted content by design (nixpkgs marks it
          insecure for exactly this), so an injected agent must not be able
          to pivot into the LAN. Internet egress stays open — the gateway
          needs its channels — and inbound + replies are unaffected
          (established/related accepted). Host-side on purpose: rules inside
          the container could be flushed by container root. Note this only
          filters ROUTED traffic; siblings on the same bridge are reachable
          at L2 regardless (bridge traffic never hits the forward hook).
        '';
      };
      lanAllowlist = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "10.0.0.5" ];
        description = ''
          IPs/CIDRs inside the blocked private ranges that openclaw MAY
          initiate connections to — LAN LLM endpoints (Ollama/vLLM) etc.
          Explicit on purpose: vllmUrl/ollamaUrl are not parsed for this, and
          the runtime openclaw.json can point anywhere, so the allowlist is
          the single place LAN reachability is granted.
        '';
      };
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # ─── Host-side egress containment ───────────────────────────
      # Own nftables table on the HOST (this module is imported by the host):
      # independent of networking.firewall settings, affects only traffic FROM
      # openclaw's IP, and survives anything the container does to itself.
      (lib.mkIf cfg.egress.restrictLan (
        let
          containerIp = lib.head (lib.splitString "/" cfg.ip);
          allowRules = lib.concatMapStringsSep "\n        " (
            dst: "ip saddr ${containerIp} ip daddr ${dst} accept"
          ) cfg.egress.lanAllowlist;
        in
        {
          networking.nftables.tables.zt-openclaw-egress = {
            family = "inet";
            content = ''
              chain forward {
                type filter hook forward priority filter; policy accept;
                ip saddr ${containerIp} ct state { established, related } accept
                ${allowRules}
                ip saddr ${containerIp} ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } limit rate 6/minute log prefix "zt-openclaw-egress drop: "
                ip saddr ${containerIp} ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } counter drop
              }
            '';
          };
        }
      ))
      (mkContainer {
        inherit config;
        name = "openclaw";
        inherit cfg;
        innerConfig = {
          # 1. Import the official OpenClaw NixOS module inside the container
          imports = [ inputs.openclaw.nixosModules.openclaw-gateway ];

          # Core primitives for Pi's subtractive design (read, write, bash)
          environment.systemPackages = with pkgs; [
            git
            bash
            curl
            jq
            python3
            nodejs
            nix
          ];

          # 2. Configure the agent
          services.openclaw-gateway = {
            enable = true;
          };

          systemd.services.openclaw-gateway = {
            preStart = lib.mkBefore ''
              # Automatically create necessary directories
              mkdir -p /var/lib/openclaw/workspace
              mkdir -p /var/lib/openclaw/agents/main/sessions
              chown -R openclaw:openclaw /var/lib/openclaw

              # Automatically generate the default configuration if it doesn't exist
              if [ ! -f /var/lib/openclaw/openclaw.json ]; then
                cat << 'EOF' > /var/lib/openclaw/openclaw.json
              {
                "agents": {
                  "defaults": {
                    "workspace": "/var/lib/openclaw/workspace"
                  }
                },
                "gateway": {
                  "mode": "local"
                }
              }
              EOF
                chown openclaw:openclaw /var/lib/openclaw/openclaw.json
              fi
            '';

            # Override environment to point to the mutable config file in the state directory
            # (instead of /etc/openclaw/openclaw.json, which is often read-only in NixOS)
            environment = {
              OPENCLAW_CONFIG_PATH = lib.mkForce "/var/lib/openclaw/openclaw.json";
              CLAWDBOT_CONFIG_PATH = lib.mkForce "/var/lib/openclaw/openclaw.json";
              CACHE_BUSTER = "1";
            };
          };

          # 3. Restrict networking so it cannot be reached from the outside
          networking.firewall.enable = true;
          # Allow outbound traffic to Internet and Ollama on bridge
        };
        bindMounts = {
          # State directory for conversations, configs, and plugins
          "/var/lib/openclaw" = {
            hostPath = cfg.hostDataDir;
            isReadOnly = false;
          };
        }
        // lib.optionalAttrs cfg.enableAudio {
          "/dev/snd" = {
            hostPath = "/dev/snd";
            isReadOnly = false;
          };
        }
        // lib.optionalAttrs cfg.enableVideo {
          "/dev/video0" = {
            hostPath = "/dev/video0";
            isReadOnly = false;
          };
          "/dev/video1" = {
            hostPath = "/dev/video1";
            isReadOnly = false;
          };
        }
        // lib.optionalAttrs cfg.enableUSB {
          "/dev/bus/usb" = {
            hostPath = "/dev/bus/usb";
            isReadOnly = false;
          };
        };
      })
    ]
  );
}
