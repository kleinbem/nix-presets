{ lib }:
{
  name,
  cfg,
  config,
  innerConfig ? { },
  bindMounts ? { },
}:
let
  inherit (lib) mkMerge mkIf mkDefault;

  # ─── mTLS Sidecar Configuration ─────────────────────────────
  hasTls = cfg ? tls && cfg.tls ? enable && cfg.tls.enable;
  tlsCfg = if hasTls then cfg.tls else { };
  serverPort = if hasTls then tlsCfg.serverPort else 0;
  upstreams = if hasTls && tlsCfg ? upstreams then tlsCfg.upstreams else [ ];

  pkiDir = "/nix/persist/pki/internal";

  # Generate Caddy upstream blocks: localhost:remotePort → remote mTLS
  mkUpstreamBlock = upstream: ''
    :${toString upstream.port} {
      reverse_proxy ${upstream.target}:${toString upstream.port} {
        transport http {
          tls
          tls_client_auth /etc/pki/internal/client.crt /etc/pki/internal/client.key
          tls_trusted_ca_certs /etc/pki/internal/ca.crt
        }
      }
    }
  '';

  upstreamBlocks = lib.concatMapStringsSep "\n" mkUpstreamBlock upstreams;

  # Caddyfile for the sidecar
  inboundBlock = if serverPort > 0 then ''
    # Inbound: accept mTLS connections and proxy to local service
    :443 {
      tls /etc/pki/internal/${name}.crt /etc/pki/internal/${name}.key {
        client_auth {
          mode require_and_verify
          trusted_ca_cert_file /etc/pki/internal/ca.crt
        }
      }
      reverse_proxy localhost:${toString serverPort}
    }
  '' else "";

  sidecarCaddyfile = ''
    {
      auto_https off
      admin off
    }

    ${inboundBlock}
    ${upstreamBlocks}
  '';

  # Firewall exceptions: allow outbound to each upstream (nftables)
  mkFwRule = upstream:
    "ip daddr ${upstream.target} tcp dport 443 accept";
  fwUpstreamRules = lib.concatMapStringsSep "\n            " mkFwRule upstreams;

in
{
  containers.${name} = {
    autoStart = true;
    privateNetwork = true;
    hostBridge = cfg.hostBridge or config.my.network.bridge;
    localAddress = cfg.ip;

    # Conditionally allow hardware device pass-through
    allowedDevices = 
      (lib.optionals (cfg.enableGPU or false) [
        {
          node = config.my.hardware.gpuRenderNode;
          modifier = "rw";
        }
      ]) ++ 
      (lib.optionals (cfg.enableAudio or false) [
        {
          node = "/dev/snd";
          modifier = "rw";
        }
      ]) ++
      (lib.optionals (cfg.enableVideo or false) [
        {
          node = "/dev/video0";
          modifier = "rw";
        }
        {
          node = "/dev/video1";
          modifier = "rw";
        }
      ]) ++
      (lib.optionals (cfg.enableUSB or false) [
        {
          node = "/dev/bus/usb";
          modifier = "rw";
        }
      ]);

    config =
      { pkgs, ... }:
      mkMerge [
        {
          networking.hostName = cfg.hostName or name;
          networking.firewall.enable = mkDefault true;
          networking.nftables.enable = mkDefault true;

          # Zero Trust: restrict outbound to bridge subnet (defense-in-depth)
          # Host-level nftables enforce the real policy; this is a second layer.
          networking.nftables.tables.zt-factory = {
            family = "inet";
            content = ''
              chain output {
                type filter hook output priority filter; policy accept;
                ct state { established, related } accept
                ip daddr 10.85.46.1 accept
                oifname "lo" accept
                ${fwUpstreamRules}
                ip daddr 10.85.46.0/24 log prefix "ZT-CTR-DENY: " drop
              }
            '';
          };

          services.avahi = {
            enable = true;
            nssmdns4 = true;
            publish = {
              enable = true;
              addresses = true;
              workstation = true;
            };
            openFirewall = true;
          };

          system.stateVersion = mkDefault "25.11";
        }

        # ─── mTLS PKI Trust (when TLS is enabled) ──────────────
        (mkIf hasTls {
          # System-wide trust for runtime-generated certs is handled via explicit sidecar config
        })

        # ─── mTLS Sidecar (only when there's inbound/outbound to proxy) ──
        (mkIf (hasTls && (serverPort > 0 || upstreams != [])) {
          # Open port 443 for inbound mTLS connections
          networking.firewall.allowedTCPPorts = lib.mkIf (serverPort > 0) [ 443 ];

          environment.systemPackages = [ pkgs.caddy ];

          # Caddy sidecar service
          systemd.services.mtls-sidecar = {
            description = "mTLS Sidecar Proxy (Caddy)";
            after = [ "network.target" ];
            wantedBy = [ "multi-user.target" ];

            serviceConfig = {
              Type = "simple";
              ExecStart = "${pkgs.caddy}/bin/caddy run --config /etc/caddy-sidecar/Caddyfile --adapter caddyfile";
              Restart = "on-failure";
              RestartSec = "5s";
              AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
            };
          };

          # Write the Caddyfile
          environment.etc."caddy-sidecar/Caddyfile".text = sidecarCaddyfile;
        })

        innerConfig
      ];

    bindMounts = bindMounts // (lib.optionalAttrs hasTls {
      # Bind-mount PKI certificates into the container
      "/etc/pki/internal/ca.crt" = {
        hostPath = "${pkiDir}/ca.crt";
        isReadOnly = true;
      };
      "/etc/pki/internal/${name}.crt" = {
        hostPath = "${pkiDir}/certs/${name}.crt";
        isReadOnly = true;
      };
      "/etc/pki/internal/${name}.key" = {
        hostPath = "${pkiDir}/certs/${name}.key";
        isReadOnly = true;
      };
      "/etc/pki/internal/client.crt" = {
        hostPath = "${pkiDir}/certs/client.crt";
        isReadOnly = true;
      };
      "/etc/pki/internal/client.key" = {
        hostPath = "${pkiDir}/certs/client.key";
        isReadOnly = true;
      };
    });
  };

  # Automatically create hostDataDir if defined
  systemd.tmpfiles.rules = mkIf (cfg ? hostDataDir && cfg.hostDataDir != null) [
    "d ${cfg.hostDataDir} 0755 1000 100 - -"
  ];

  # Inject resource limits into the systemd unit on the host
  systemd.services."container@${name}".serviceConfig =
    mkIf ((cfg ? memoryLimit && cfg.memoryLimit != null) || (cfg ? cpuLimit && cfg.cpuLimit != null))
      {
        MemoryMax = mkIf (cfg ? memoryLimit && cfg.memoryLimit != null) cfg.memoryLimit;
        CPUQuota = mkIf (cfg ? cpuLimit && cfg.cpuLimit != null) cfg.cpuLimit;
      };
}
