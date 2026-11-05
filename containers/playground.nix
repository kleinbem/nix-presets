{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.playground;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.playground = {
    enable = lib.mkEnableOption "Development Playground Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    user = lib.mkOption {
      type = lib.types.str;
      default = "martin";
      description = "The username to create inside the container.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "8G";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "playground";
    inherit cfg;
    innerConfig = {
      users.users.${cfg.user} = {
        isNormalUser = true;
        uid = 1000;
        extraGroups = [
          "users"
          "wheel"
          "networkmanager"
        ];
        shell = pkgs.zsh;
      };

      # Standard Development Environment
      environment.systemPackages = with pkgs; [
        git
        neovim
        direnv
        zsh
        btop
        curl
        wget
        nix-tree
        nh
        nixfmt
      ];

      # Nix-in-Nix and experimental features
      nix = {
        package = pkgs.nixVersions.stable;
        settings = {
          experimental-features = [
            "nix-command"
            "flakes"
          ];
          trusted-users = [
            "root"
            cfg.user
          ];
          substituters = [ "https://cache.nixos.org" ];
          trusted-public-keys = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" ];
        };
      };

      programs.zsh.enable = true;
      programs.direnv.enable = true;

      # Network Hardening: Allow only DNS + HTTPS (for Nix cache), block access to other containers
      networking.firewall = {
        enable = true;
        allowedTCPPorts = [ ]; # No inbound services
      };
      # Block outbound traffic to the container bridge subnet (other services)
      # but allow DNS and HTTPS for nix builds
      networking.nftables = {
        enable = true;
        ruleset = ''
          table inet playground-isolation {
            chain output {
              type filter hook output priority 0; policy accept;
              # Allow loopback
              oifname "lo" accept
              # Allow DNS (needed for nix builds)
              tcp dport 53 accept
              udp dport 53 accept
              # Allow established connections
              ct state established,related accept
              # Block access to the container bridge subnet (other services)
              ip daddr 10.85.46.0/24 drop
            }
          }
        '';
      };
    };
    bindMounts = {
      "/home/${cfg.user}/playground" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    };
  });
}
