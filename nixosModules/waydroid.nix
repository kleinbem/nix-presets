{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.waydroid-setup;
in
{
  options.programs.waydroid-setup = {
    enable = lib.mkEnableOption "Waydroid setup tools and system configuration";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.system}.default;
      description = "The waydroid-setup package providing the bootstrap tool.";
    };
  };

  config = lib.mkIf cfg.enable {
    # System settings required for Waydroid to function
    virtualisation.waydroid.enable = lib.mkDefault true;
    virtualisation.lxc.enable = lib.mkDefault true;

    # Waydroid needs these kernel environment settings
    boot.kernelParams = [ "psi=1" ];
    boot.kernelModules = [
      "uhid"
      "binder_linux"
    ];

    # Fix for Magisk/LXC: Allow nested mounts and unprivileged user namespaces
    boot.kernel.sysctl = {
      "kernel.unprivileged_userns_clone" = lib.mkDefault 1;
    };

    # Override the Waydroid service to allow the required mounts and capabilities
    # for Magisk to setup its internal tmpfs environment.
    systemd.services.waydroid-container = {
      description = lib.mkForce "Waydroid Container (Unconfined for Magisk)";
      serviceConfig = {
        # This allows the container to perform necessary system-level mounts
        CapabilityBoundingSet = [ "~" ]; # Effectively allows all caps
        ProtectSystem = lib.mkForce "no";
        ProtectHome = lib.mkForce "no";
        PrivateDevices = lib.mkForce false;
      };

      # Automatically patch the Waydroid LXC config to allow Magisk mounts
      preStart = ''
        if [ -f /var/lib/waydroid/lxc/waydroid/config ]; then
          # Remove existing entries to avoid duplicates
          sed -i '/lxc.mount.auto/d' /var/lib/waydroid/lxc/waydroid/config
          sed -i '/lxc.cap.drop/d' /var/lib/waydroid/lxc/waydroid/config
          sed -i '/lxc.apparmor.profile/d' /var/lib/waydroid/lxc/waydroid/config
          sed -i '/lxc.seccomp.allow_nesting/d' /var/lib/waydroid/lxc/waydroid/config
          sed -i '/lxc.no_new_privs/d' /var/lib/waydroid/lxc/waydroid/config
          
          # Add Magisk-compatible settings
          echo "lxc.mount.auto = proc:rw sys:rw cgroup:rw" >> /var/lib/waydroid/lxc/waydroid/config
          echo "lxc.cap.drop =" >> /var/lib/waydroid/lxc/waydroid/config
          echo "lxc.apparmor.profile = unconfined" >> /var/lib/waydroid/lxc/waydroid/config
          echo "lxc.seccomp.allow_nesting = 1" >> /var/lib/waydroid/lxc/waydroid/config
          echo "lxc.no_new_privs = 0" >> /var/lib/waydroid/lxc/waydroid/config
        fi
      '';
    };

    # Fix for waydroid0 bridge issues
    # Pre-creating the bridge ensures Waydroid starts reliably
    networking.bridges."waydroid0".interfaces = lib.mkDefault [ ];

    # Enable nftables by default as Waydroid works best with it now
    networking.nftables.enable = lib.mkDefault true;

    environment.systemPackages = [
      cfg.package
      self.packages.${pkgs.system}.get-id
      self.packages.${pkgs.system}.status
      self.packages.${pkgs.system}.uninstall
      self.packages.${pkgs.system}.update-pif
      self.packages.${pkgs.system}.restart
      self.packages.${pkgs.system}.activate
    ];
  };
}
