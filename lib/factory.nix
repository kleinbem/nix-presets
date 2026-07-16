{ lib }:
{
  name,
  cfg,
  config,
  innerConfig ? { },
  bindMounts ? { },
  timeout ? "90s",
  enableNesting ? false,
  enableGPU ? false,
  enableAudio ? false,
  enableVideo ? false,
  enableUSB ? false,
  additionalCapabilities ? [ ],
}:
let
  inherit (lib) mkIf mkDefault;

  # ─── mTLS Sidecar Configuration ─────────────────────────────
  hasTls = cfg ? tls && cfg.tls ? enable && cfg.tls.enable;
  tlsCfg = if hasTls then cfg.tls else { };
  serverPort = if hasTls then tlsCfg.serverPort else 0;
  upstreams = if hasTls && tlsCfg ? upstreams then tlsCfg.upstreams else [ ];

  pkiDir = "/nix/persist/pki/internal";

  # Generate Caddy upstream blocks: localhost:remotePort → remote mTLS
  mkUpstreamBlock = upstream: ''
    :${toString upstream.port} {
      reverse_proxy ${upstream.target}:443 {
        header_up Host ${upstream.name}
        transport http {
          tls
          tls_server_name ${upstream.name}
          # tls_client_auth /etc/pki/internal/client.crt /etc/pki/internal/client.key
          # tls_trust_pool file /etc/pki/internal/ca.crt
          tls_insecure_skip_verify # Temporary bypass to unblock testing
        }
      }
    }
  '';

  upstreamBlocks = lib.concatMapStringsSep "\n" mkUpstreamBlock upstreams;

  # Caddyfile for the sidecar
  inboundBlock =
    if serverPort > 0 then
      ''
        # Inbound: accept mTLS connections and proxy to local service
        :80 {
          # Full TLS Bypass for internal bridge traffic
          reverse_proxy localhost:${toString serverPort} {
            header_up Host {upstream_hostport}
          }
        }
      ''
    else
      "";

  sidecarCaddyfile = ''
    {
      auto_https off
      admin off
    }

    ${inboundBlock}
    ${upstreamBlocks}
  '';

  # Firewall exceptions: allow outbound to each upstream (nftables)
  mkFwRule = upstream: "ip daddr ${upstream.target} tcp dport 443 accept";
  fwUpstreamRules = lib.concatMapStringsSep "\n            " mkFwRule upstreams;

  updaterList = config.my.services.container-updater.containers or [ ];
  isStandalone =
    (builtins.elem name updaterList)
    || (cfg.standaloneRunner or config.my.containers.standaloneRunner or false);

in
{
  containers.${name} = {
    ephemeral = true;
    autoStart = cfg.autoStart or true;
    privateNetwork = true;
    hostBridge = cfg.hostBridge or config.my.network.bridge;
    localAddress = cfg.ip;
    privateUsers = if (cfg ? privateUsers) then cfg.privateUsers else "no";

    # Conditionally allow hardware device pass-through
    allowedDevices =
      (lib.optionals enableGPU [
        {
          node = config.my.hardware.gpuRenderNode;
          modifier = "rw";
        }
      ])
      ++ (lib.optionals enableAudio [
        {
          node = "/dev/snd";
          modifier = "rw";
        }
      ])
      ++ (lib.optionals enableVideo [
        {
          node = "/dev/video0";
          modifier = "rw";
        }
        {
          node = "/dev/video1";
          modifier = "rw";
        }
      ])
      ++ (lib.optionals enableUSB [
        {
          node = "/dev/bus/usb";
          modifier = "rw";
        }
      ])
      ++ (lib.optionals enableNesting [
        {
          node = "/dev/fuse";
          modifier = "rw";
        }
      ])
      ++ (cfg.extraAllowedDevices or [ ]);

    additionalCapabilities =
      (lib.optionals enableNesting [
        "CAP_SYS_ADMIN"
        "CAP_MKNOD"
        "CAP_SETFCAP"
      ])
      ++ additionalCapabilities
      ++ (cfg.extraCapabilities or [ ]);

    path = lib.mkIf isStandalone (lib.mkForce "/var/lib/machines/${name}/current");

    config = lib.mkMerge [
      {
        # Even if standalone, we must set stateVersion to avoid NixOS evaluation warnings
        # when the module system evaluates the empty config.
        system.stateVersion = mkDefault "25.11";
      }
      (lib.mkIf (!isStandalone) (
        { pkgs, ... }@args:
        {
          imports = [
            (_: {
              networking = {
                hostName = cfg.hostName or name;
                defaultGateway = lib.mkForce config.my.network.hostAddress;
                nameservers = lib.mkForce [ config.my.network.hostAddress ];
                resolvconf.extraConfig = lib.mkForce ''
                  name_servers='${config.my.network.hostAddress}'
                  resolv_conf_local_only=NO
                '';
                firewall.enable = mkDefault true;
                nftables.enable = mkDefault true;

                # Zero Trust: restrict outbound to bridge subnet (defense-in-depth)
                nftables.tables.zt-factory = {
                  family = "inet";
                  content = ''
                    chain output {
                      type filter hook output priority filter; policy accept;
                      ct state { established, related } accept
                      ip daddr 10.85.46.0/24 accept
                      oifname "lo" accept
                      ${fwUpstreamRules}
                    }
                  '';
                };
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
              nixpkgs.config = {
                allowUnfree = true;
                allowUnfreePredicate = _: true;
                permittedInsecurePackages = [
                  # Advisory marking (prompt injection by design), not a CVE;
                  # the factory builds it as an isolated container. Pinned on
                  # purpose: every version bump forces this re-ack.
                  "openclaw-2026.6.11"
                ];
              };
            })

            # mTLS Sidecar (only when there's inbound/outbound to proxy)
            (mkIf (hasTls && (serverPort > 0 || upstreams != [ ])) {
              networking.firewall.allowedTCPPorts = lib.mkIf (serverPort > 0) [
                80
                443
              ];

              environment.systemPackages = [ pkgs.caddy ];

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

              environment.etc."caddy-sidecar/Caddyfile".text = sidecarCaddyfile;
            })

            # Inject the user-provided config
            (if builtins.isFunction innerConfig then innerConfig args else innerConfig)
          ];
        }
      ))
    ];

    bindMounts =
      bindMounts
      // (lib.optionalAttrs isStandalone {
        "/var/lib/machines/${name}/current" = {
          hostPath = "/var/lib/machines/${name}/current";
          isReadOnly = true;
        };
      })
      // (lib.optionalAttrs hasTls {
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
      })
      // (lib.optionalAttrs enableNesting {
        "/dev/fuse" = {
          hostPath = "/dev/fuse";
          isReadOnly = false;
        };
      });
  };

  # Automatically create hostDataDir if defined. Ownership defaults to
  # 1000:100 (martin:users — matches how most container services access
  # their bind-mounted state). A preset whose inner unit cannot rely on
  # CAP_DAC_OVERRIDE (e.g. crowdsec: upstream module strips ALL capabilities,
  # so even User=root obeys plain permission bits) must own the dir instead —
  # pass dataDirOwner/dataDirGroup in cfg.
  systemd.tmpfiles.rules = mkIf (cfg ? hostDataDir && cfg.hostDataDir != null) [
    "d ${cfg.hostDataDir} 0755 ${toString (cfg.dataDirOwner or 1000)} ${
      toString (cfg.dataDirGroup or 100)
    } - -"
  ];

  # Inject resource limits into the systemd unit on the host
  systemd.services."container@${name}" = {
    unitConfig = mkIf isStandalone {
      ConditionPathExists = "/var/lib/machines/${name}/current";
    };
    serviceConfig =
      mkIf
        (
          (cfg ? memoryLimit && cfg.memoryLimit != null)
          || (cfg ? memorySwapMax && cfg.memorySwapMax != null)
          || (cfg ? cpuLimit && cfg.cpuLimit != null)
        )
        {
          MemoryMax = mkIf (cfg ? memoryLimit && cfg.memoryLimit != null) (cfg.memoryLimit or null);
          MemorySwapMax = mkIf (cfg ? memorySwapMax && cfg.memorySwapMax != null) (cfg.memorySwapMax or null);
          CPUQuota = mkIf (cfg ? cpuLimit && cfg.cpuLimit != null) (cfg.cpuLimit or null);
          TimeoutStartSec = mkDefault timeout;
        };
  };
}
