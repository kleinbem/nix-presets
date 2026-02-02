{ pkgs, nixpak, ... }:

let
  utils = import ./utils.nix { inherit pkgs nixpak; };

  # Define the policy file directly via Nix
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

  # This replaces the standard xdg-open with one that talks to the portal via DBus.
  # This allows opening apps on the host (like Github Desktop) from within the sandbox.
  mkSandboxedXdgUtils = pkgs.writeShellScriptBin "xdg-open" ''
    # Using dbus-send to communicate with xdg-desktop-portal
    # https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.OpenURI.html

    LOGFILE="/tmp/xdg-open-debug.log"
    echo "--- xdg-open called at $(date) ---" >> "$LOGFILE"
    echo "Args: $@" >> "$LOGFILE"
    echo "DBUS_SESSION_BUS_ADDRESS: $DBUS_SESSION_BUS_ADDRESS" >> "$LOGFILE"

    # Check if we have arguments
    if [ -z "$1" ]; then
      echo "Usage: xdg-open <url>"
      exit 1
    fi

    # Call the OpenURI portal
    # method call time:1735235242.067332 sender=:1.86 -> destination=org.freedesktop.portal.Desktop serial=344 path=/org/freedesktop/portal/desktop; interface=org.freedesktop.portal.OpenURI; member=OpenURI
    #    string ""
    #    string "https://google.com"
    #    array [
    #    ]

    # We use system-bus if DBUS_SESSION_BUS_ADDRESS is not set, but it should be set in sandbox
    ${pkgs.dbus}/bin/dbus-send \
      --session \
      --print-reply \
      --dest=org.freedesktop.portal.Desktop \
      /org/freedesktop/portal/desktop \
      org.freedesktop.portal.OpenURI.OpenURI \
      string:"" \
      string:"$1" \
      array:dict:string:variant: >> "$LOGFILE" 2>&1
  '';

  # Wrap the script in a package structure similar to xdg-utils
  sandboxedXdgUtils = pkgs.symlinkJoin {
    name = "sandboxed-xdg-utils";
    paths = [
      mkSandboxedXdgUtils
      pkgs.xdg-utils
    ]; # Prefer our xdg-open over the one in xdg-utils
  };
  # Helper to generate sandboxed Chrome with custom user data directories
  # This allows us to have isolated 'Vault', 'Hazard', and 'Standard' profiles
  # that all run in the same restricted sandbox structure, but bind different storage.
  mkChrome =
    {
      name, # Binary name (e.g., google-chrome-vault)
      sourceUserDataDir ? null, # Host dir to bind to ~/.config/google-chrome (if null, uses standard ~/.config/google-chrome)
      exportDesktopFiles ? true,
      extraBinNames ? [ ],
      policy ? chromePolicyBlocked,
      ...
    }:
    utils.mkSandboxed {
      inherit exportDesktopFiles;
      inherit extraBinNames;
      package = pkgs.runCommand "google-chrome-renamed-${name}" { } ''
        mkdir -p $out/bin
        ln -s ${pkgs.google-chrome}/bin/google-chrome-stable $out/bin/${name}
        ln -s ${pkgs.google-chrome}/share $out/share
      '';
      inherit name;
      binPath = "bin/${name}";
      # configDir = "google-chrome"; # REMOVED: Caused collision with default profile. Defaults to 'name' now.
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
              # Conditional Binding: Bind custom host dir to standard internal dir
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
              # If we are binding a custom Config Dir, we DON'T need to set CHROME_USER_DATA_DIR
              # because we are mounting it to the default location inside the sandbox!
              # But if we were NOT rebinding (standard case), util.mkSandboxed handles configDir binding.
              # Actually, util.mkSandboxed binds the host 'configDir' to ~/.config/name.
              # Since we force 'configDir = "google-chrome"', it binds ~/.config/google-chrome <-> ~/.config/google-chrome
              # WE NEED TO OVERRIDE THIS BEHAVIOR for custom source dirs.
              # The simplest way with utils.mkSandboxed is to let it bind the default, and we OVERMOUNT it with our bind in 'rw'.
              # Bubblewrap processes binds in order.

              DBUS_SESSION_BUS_ADDRESS = sloth.env "DBUS_SESSION_BUS_ADDRESS";
              NIXOS_OZONE_WL = "1";
            };
          };
        };
    };
in
{
  # --- OBSIDIAN ---
  obsidian = utils.mkSandboxed {
    package = pkgs.obsidian;
    presets = [
      "wayland"
      "gpu"
      "network"
    ];
    extraPerms =
      { sloth, ... }:
      {
        bubblewrap.bind.rw = [
          (sloth.concat' sloth.homeDir "/GoogleDrive/Obsidian")
        ];
      };
  };

  # 1. Standard Banking (Vault) - Isolated Storage
  google-chrome-stable-vault = mkChrome {
    name = "google-chrome-stable-vault";
    sourceUserDataDir = "/home/martin/.config/google-chrome-vault";
    exportDesktopFiles = true;
    displayName = "Google Chrome Vault (Secure)";
    policy = chromePolicyBlocked;
  };

  # 2. Social Media (Hazard) - Isolated Storage
  google-chrome-stable-hazard = mkChrome {
    name = "google-chrome-stable-hazard";
    sourceUserDataDir = "/home/martin/.config/google-chrome-hazard";
    exportDesktopFiles = true;
    displayName = "Google Chrome Hazard (Secure)";
    policy = chromePolicyBlocked;
  };

  # 3. Standard Chrome (matches upstream name)
  google-chrome-stable = mkChrome {
    name = "google-chrome-stable";
    # Force usage of ~/.config/google-chrome to preserve existing profile
    # Since we renamed the binary to 'google-chrome-stable', default Chrome checking would likely look for ~/.config/google-chrome-stable
    # We must explicitly bind the old directory to ensure continuity.
    sourceUserDataDir = "/home/martin/.config/google-chrome";
    extraBinNames = [ "google-chrome" ]; # Alias for convenience
    displayName = "Google Chrome (Secure)";
    policy = chromePolicyAllowed;
  };

  # --- MPV (Media Player) ---
  mpv = utils.mkSandboxed {
    package = pkgs.mpv;
    name = "mpv";
    presets = [
      "wayland"
      "gpu"
      "audio"
      "network"
    ];
    extraPerms =
      { sloth, ... }:
      {
        bubblewrap.bind = {
          rw = [
            (sloth.concat' sloth.homeDir "/.config/mpv")
          ];
          # Media Folders (Read-only for safety)
          ro = [
            (sloth.concat' sloth.homeDir "/Videos")
            (sloth.concat' sloth.homeDir "/Music")
            (sloth.concat' sloth.homeDir "/Downloads")
          ];
        };
      };
  };

  # --- LM STUDIO ---
  lmstudio = utils.mkSandboxed {
    package = pkgs.lmstudio;
    name = "lmstudio";
    presets = [
      "wayland"
      "gpu"
      "audio"
      "network"
    ];
    extraPerms = _: {
      bubblewrap.bind = {
        rw = [
          # Model storage
          "/images/lmstudio"
        ];
      };
    };
  };

  # --- DISCORD ---
  discord = utils.mkSandboxed {
    package = pkgs.stable.discord;
    name = "discord";
    configDir = "discord";
    extraPackages = [ sandboxedXdgUtils ];
    presets = [
      "wayland"
      "gpu"
      "audio"
      "network"
    ];
    extraPerms =
      { sloth, ... }:
      {
        bubblewrap = {
          bind = {
            rw = [
              # Downloads for saving files
              (sloth.concat' sloth.homeDir "/Downloads")
            ];
          };
          env = {
            # Open links on host
            DBUS_SESSION_BUS_ADDRESS = sloth.env "DBUS_SESSION_BUS_ADDRESS";
            BROWSER = "xdg-open";
            NIXOS_OZONE_WL = "1";
          };
        };
      };
  };

  # --- SLACK ---
  slack = utils.mkSandboxed {
    package = pkgs.stable.slack;
    name = "slack";
    configDir = "Slack";
    extraPackages = [ sandboxedXdgUtils ];
    presets = [
      "wayland"
      "gpu"
      "audio"
      "network"
    ];
    extraPerms =
      { sloth, ... }:
      {
        bubblewrap = {
          bind = {
            rw = [
              # Downloads
              (sloth.concat' sloth.homeDir "/Downloads")
            ];
          };
          env = {
            DBUS_SESSION_BUS_ADDRESS = sloth.env "DBUS_SESSION_BUS_ADDRESS";
            BROWSER = "xdg-open";
            NIXOS_OZONE_WL = "1";
          };
        };
      };
  };

  # --- SIGNAL ---
  signal-desktop = utils.mkSandboxed {
    package = pkgs.stable.signal-desktop;
    name = "signal-desktop";
    configDir = "Signal";
    extraPackages = [ sandboxedXdgUtils ];
    presets = [
      "wayland"
      "gpu"
      "audio"
      "network"
    ];
    extraPerms =
      { sloth, ... }:
      {
        bubblewrap = {
          bind = {
            rw = [
              # Downloads
              (sloth.concat' sloth.homeDir "/Downloads")
            ];
          };
          env = {
            DBUS_SESSION_BUS_ADDRESS = sloth.env "DBUS_SESSION_BUS_ADDRESS";
            BROWSER = "xdg-open";
            NIXOS_OZONE_WL = "1";
          };
        };
      };
  };

  # --- BITWARDEN ---
  bitwarden = utils.mkSandboxed {
    package = pkgs.stable.bitwarden-desktop;
    name = "bitwarden";
    configDir = "Bitwarden";
    presets = [
      "wayland"
      "gpu"
      "network"
    ];
    extraPerms = _: {
      bubblewrap.bind = {
        rw = [
          # No extra file access needed, just the config dir which utils handles
        ];
      };
    };
  };

  # --- GITHUB DESKTOP ---
  github-desktop = utils.mkSandboxed {
    package = pkgs.github-desktop;
    name = "github-desktop";
    configDir = "GitHub Desktop";
    extraPackages = [
      sandboxedXdgUtils
      pkgs.git
      pkgs.openssh
    ];
    presets = [
      "wayland"
      "gpu"
      "network"
    ];
    extraPerms =
      { sloth, ... }:
      {
        bubblewrap = {
          bind = {
            rw = [
              # Code Repositories
              (sloth.concat' sloth.homeDir "/Develop")
            ];
            ro = [
              # Git & SSH Config
              (sloth.concat' sloth.homeDir "/.gitconfig")
              (sloth.concat' sloth.homeDir "/.ssh")
            ];
          };
          env = {
            # SSH Agent for YubiKey auth
            SSH_AUTH_SOCK = sloth.env "SSH_AUTH_SOCK";
            # Enable System Integration (Open Links/Apps) via DBus
            DBUS_SESSION_BUS_ADDRESS = sloth.env "DBUS_SESSION_BUS_ADDRESS";
            # Force invocation of our xdg-open wrapper
            BROWSER = "xdg-open";
          };
        };
      };
  };
}
