{
  pkgs,
  lib,
  ...
}:

let
  commonData = import ./code-common/settings.nix;
  extensions = import ./code-common/extensions.nix { inherit pkgs; };

  # Helper to bundle extensions
  mkBundle =
    name: exts:
    pkgs.symlinkJoin {
      name = "${name}-extensions-bundle";
      paths = exts;
    };

  bundleAntigravity = mkBundle "antigravity" (
    extensions.common ++ extensions.ai ++ extensions.vscodeExtra
  );
  bundleCursor = mkBundle "cursor" (extensions.common ++ extensions.ai ++ extensions.cursorExtra);
  bundleWindsurf = mkBundle "windsurf" (extensions.common ++ extensions.ai);

  # The Unified "Code Family"
  codeFamily = [
    {
      name = "Antigravity";
      configDir = ".config/antigravity";
      extDir = ".config/antigravity/extensions";
      bundle = bundleAntigravity;
    }
    {
      name = "Cursor";
      configDir = ".config/cursor";
      extDir = ".config/cursor/extensions";
      bundle = bundleCursor;
    }
    {
      name = "Windsurf";
      configDir = ".config/windsurf";
      extDir = ".config/windsurf/extensions";
      bundle = bundleWindsurf;
    }
  ];

  # Helper to write JSON config
  mkConfigs = app: {
    "${app.configDir}/settings.json".text = builtins.toJSON commonData.settings;
    "${app.configDir}/keybindings.json".text = builtins.toJSON commonData.keybindings;
  };

  # Wrapper generator for strict isolation
  mkIsolatedEditor =
    app:
    let
      # Use the exact package names confirmed from search.nixos.org
      pkg =
        if app.name == "Windsurf" then
          pkgs.windsurf
        else if app.name == "Cursor" then
          pkgs.code-cursor-fhs
        else
          pkgs.antigravity-fhs;

      # Correct binary names for the FHS wrappers
      binName =
        if app.name == "Cursor" then
          "cursor"
        else if app.name == "Antigravity" then
          "antigravity"
        else
          "windsurf";
    in
    pkgs.writeShellScriptBin (lib.toLower app.name) ''
      exec ${pkg}/bin/${binName} \
        --user-data-dir "$HOME/${app.configDir}/data" \
        --extensions-dir "$HOME/${app.extDir}" \
        "$@"
    '';

in
{
  imports = [
    ./mcp.nix
  ];

  home = {
    packages = with pkgs; [
      # Unified Code Platform Editors (Isolated Wrappers)
      (mkIsolatedEditor (builtins.elemAt codeFamily 0)) # Antigravity
      (mkIsolatedEditor (builtins.elemAt codeFamily 1)) # Cursor
      (mkIsolatedEditor (builtins.elemAt codeFamily 2)) # Windsurf

      warp-terminal
      pavucontrol
      nwg-look
      mission-center # System Monitor (Task Manager)
      p7zip # Archives
      rclone-browser # GUI for Rclone
      restic-browser # GUI for Restic Backups
      restic # CLI Tool (Required for Restic Browser)

      # --- Communication ---
      discord
      signal-desktop

      # -- Apps (Sandboxed via Firejail on host) --
      obsidian
      logseq
      mpv
      google-chrome
      bitwarden-desktop
      zathura
      imv # Image Viewer
      pkgs.rbw
      pkgs.rofi-rbw-wayland
      pkgs.brotab # Browser Automation (asked by user)
      pkgs.cliphist # Clipboard history
      pkgs.wl-clipboard # Required for cliphist

      # -- Volatile tools moved to DevShells --
      # Run: just pentest    (Wireshark, Chromium, Metasploit, etc.)
      # Run: just ai-dev     (claude-code, lmstudio, fabric-ai, etc.)
      # Run: just math       (octaveFull, typst, tinymist)
      # Run: just media      (obs-studio)

      nixd # Nix Language Server
    ];

    # Generate declarative config files for all agents
    file = lib.mkMerge (map mkConfigs codeFamily);

    # Create cloud mount directories for rclone
    activation.createCloudMounts = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD mkdir -p $HOME/GoogleDrive $HOME/OneDrive
    '';

    # Sync Extensions Script (Runs on switch)
    # This creates symlinks from the generated extensions.nix profile to each editor's extension dir.
    activation.syncCodeFamily = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${lib.concatMapStrings (app: ''
        echo "⚡ Syncing ${app.name} extensions to isolated storage..."
        mkdir -p $HOME/${app.extDir}
        mkdir -p $HOME/${app.configDir}/data

        # Link each extension from the Nix profile (app.bundle)
        # We iterate over the store path to find the extensions
        for ext in ${app.bundle}/share/vscode/extensions/*; do
          target="$HOME/${app.extDir}/$(basename $ext)"
          
          # Force remove existing target (link or dir) to prevent dereferencing
          if [ -e "$target" ] || [ -L "$target" ]; then
            rm -rf "$target"
          fi
          
          # Create fresh symlink
          ln -sf "$ext" "$target"
        done

      '') codeFamily}
    '';
  };

  # Force Qt apps to use GTK theme (fixes rclone-browser dark mode)
  gtk = {
    enable = true;
    theme = {
      name = "Adwaita-dark";
      package = pkgs.gnome-themes-extra;
    };
  };

  qt = {
    enable = true;
    platformTheme.name = "gtk";
  };

  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "x-scheme-handler/x-github-client" = [ "github-desktop.desktop" ];
      "text/html" = [ "firefox.desktop" ];
      "x-scheme-handler/http" = [ "firefox.desktop" ];
      "x-scheme-handler/https" = [ "firefox.desktop" ];
      "x-scheme-handler/about" = [ "firefox.desktop" ];
      "x-scheme-handler/unknown" = [ "firefox.desktop" ];
      "x-scheme-handler/obsidian" = [ "obsidian.desktop" ];
    };
  };

  # Create a custom "Fortress" launcher for BOI
  xdg.desktopEntries = { };

  programs.waybar.enable = true;

  systemd.user.services = {
    rclone-gdrive-mount = {
      Unit = {
        Description = "Mount Google Drive via Rclone";
        After = [ "network-online.target" ];
      };
      Service = {
        Type = "simple";
        Environment = "PATH=/run/wrappers/bin:$PATH";
        # Wait for network to be fully ready before mounting
        ExecStartPre = [
          "${pkgs.coreutils}/bin/sleep 5"
          "${pkgs.coreutils}/bin/mkdir -p %h/GoogleDrive"
        ];
        ExecStart = ''
          ${pkgs.rclone}/bin/rclone mount gdrive: %h/GoogleDrive \
            --allow-other \
            --allow-non-empty \
            --vfs-cache-mode full \
            --vfs-cache-max-size 10G \
            --vfs-cache-max-age 24h \
            --dir-cache-time 1000h \
            --log-level INFO
        '';
        ExecStop = "/run/wrappers/bin/fusermount3 -u %h/GoogleDrive";
        Restart = "on-failure";
        RestartSec = "10s";
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };

    rclone-onedrive-mount = {
      Unit = {
        Description = "Mount OneDrive via Rclone";
        After = [ "network-online.target" ];
      };
      Service = {
        Type = "simple";
        Environment = "PATH=/run/wrappers/bin:$PATH";
        # Wait for network to be fully ready before mounting
        ExecStartPre = [
          "${pkgs.coreutils}/bin/sleep 5"
          "${pkgs.coreutils}/bin/mkdir -p %h/OneDrive"
        ];
        ExecStart = ''
          ${pkgs.rclone}/bin/rclone mount onedrive: %h/OneDrive \
            --allow-other \
            --allow-non-empty \
            --vfs-cache-mode full \
            --vfs-cache-max-size 10G \
            --vfs-cache-max-age 24h \
            --dir-cache-time 1000h \
            --log-level INFO
        '';
        ExecStop = "/run/wrappers/bin/fusermount3 -u %h/OneDrive";
        Restart = "on-failure";
        RestartSec = "10s";
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };

    cliphist = {
      Unit = {
        Description = "Clipboard history service (cliphist)";
        After = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.wl-clipboard}/bin/wl-paste --watch ${pkgs.cliphist}/bin/cliphist store";
        Restart = "on-failure";
      };
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
