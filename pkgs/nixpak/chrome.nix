{ pkgs, nixpak, ... }:

let
  utils = import ../../nixpak/utils.nix { inherit pkgs nixpak; };
  sandboxedXdgUtils = pkgs.callPackage ../../nixpak/xdg-utils.nix { };

  # Define the policy file directly via Nix
  chromePolicyBlocked = pkgs.runCommand "chrome-policy-blocked" { } ''
    mkdir -p $out/policies/managed
    cat > $out/policies/managed/blocklist.json <<EOF
    ${builtins.toJSON {
      ExtensionInstallBlocklist = [
        "ghbmnnjooekpmoecnnnilnnbdlolhkhi" # Google Drive Offline
        "aohghmighlieiainnegkcijnfilokake" # Google Docs
        "felcaaldnbdncclmgdcncolpebgiejap" # Google Sheets
        "aapocclcgogkmnckokdopfmhonfmgoek" # Google Slides
        "pjkljhegncpnkpknbcohdijeoejaedia" # Gmail
        "blpcfgokakmgnkcojhhkbfbldkacnbeo" # YouTube
      ];
    }}
    EOF
  '';

  # Define a permissive policy (empty blocklist)
  chromePolicyAllowed = pkgs.runCommand "chrome-policy-allowed" { } ''
    mkdir -p $out/policies/managed
    cat > $out/policies/managed/blocklist.json <<EOF
    ${builtins.toJSON {
      ExtensionInstallBlocklist = [ ];
    }}
    EOF
  '';

  # Define a dummy machine-id file
  dummyMachineId = pkgs.writeText "machine-id" "00000000000000000000000000000000\n";

  mkChrome =
    {
      name, # Binary name (e.g., google-chrome-vault)
      sourceUserDataDir ? null, # Host dir to bind to ~/.config/google-chrome
      exportDesktopFiles ? true,
      extraBinNames ? [ ],
      policy ? chromePolicyBlocked,
      resourceLimits ? null,
      # _displayName,
      ...
    }:
    utils.mkSandboxed {
      inherit exportDesktopFiles;
      inherit extraBinNames;
      inherit resourceLimits;
      package = pkgs.runCommand "google-chrome-renamed-${name}" { } ''
        mkdir -p $out/bin
        ln -s ${pkgs.google-chrome}/bin/google-chrome-stable $out/bin/${name}
        ln -s ${pkgs.google-chrome}/share $out/share
      '';
      inherit name;
      binPath = "bin/${name}";
      extraPackages = [
        sandboxedXdgUtils
        pkgs.cosmic-files
        pkgs.brotab
      ];
      presets = [
        "network"
        "wayland"
        "audio"
        "gpu"
        "usb"
      ];
      extraPerms =
        { sloth, ... }:
        {
          bubblewrap = {
            bind = {
              # 1. Device Access
              dev = [
                "/dev/bus/usb"
                "/dev/video0"
                "/dev/video1"
              ]
              ++ (map (i: "/dev/hidraw" + toString i) (pkgs.lib.lists.range 0 49));

              # 2. File & Socket Access
              rw = [
                # YubiKey / Smart Card (FIDO2)
                "/run/pcscd"

                # Downloads
                (sloth.concat' sloth.homeDir "/Downloads")

                # PWA Integration (Shared)
                (sloth.concat' sloth.homeDir "/.local/share/applications")
                (sloth.concat' sloth.homeDir "/.local/share/icons")
                (sloth.concat' sloth.homeDir "/.config/mimeapps.list")
              ]
              # Conditional Binding
              ++ pkgs.lib.optionals (sourceUserDataDir != null) [
                [
                  sourceUserDataDir
                  (sloth.concat' sloth.homeDir "/.config/google-chrome")
                ]
              ];

              # 3. Read Only Access
              ro = [
                (sloth.concat' sloth.homeDir "/.local/share/fonts")
                (sloth.concat' sloth.homeDir "/.config/gtk-3.0")
                [
                  "${policy}"
                  "/etc/opt/chrome"
                ]
                [
                  "${dummyMachineId}"
                  "/etc/machine-id"
                ]
                "/sys/class/hidraw"
                "/sys/bus/hid"
                "/sys/devices"
                "/run/udev/data"
                "/run/udev"
              ];
            };
            env = {
              DBUS_SESSION_BUS_ADDRESS = sloth.env "DBUS_SESSION_BUS_ADDRESS";
              NIXOS_OZONE_WL = "1";
            };
          };
        };
    };
in
{
  # 1. Standard Banking (Vault) - Isolated Storage
  vault = mkChrome {
    name = "google-chrome-stable-vault";
    sourceUserDataDir = "/home/martin/.config/google-chrome-vault";
    exportDesktopFiles = true;
    displayName = "Google Chrome Vault (Secure)";
    policy = chromePolicyBlocked;
  };

  # 2. Social Media (Hazard) - Isolated Storage
  hazard = mkChrome {
    name = "google-chrome-stable-hazard";
    sourceUserDataDir = "/home/martin/.config/google-chrome-hazard";
    exportDesktopFiles = true;
    displayName = "Google Chrome Hazard (Secure)";
    policy = chromePolicyBlocked;
  };

  # 3. Standard Chrome (matches upstream name)
  stable = mkChrome {
    name = "google-chrome-stable";
    sourceUserDataDir = "/home/martin/.config/google-chrome";
    extraBinNames = [ "google-chrome" ];
    displayName = "Google Chrome (Secure)";
    policy = chromePolicyAllowed;
    resourceLimits = {
      cpu = "400%";
      mem = "12G";
    };
  };
}
