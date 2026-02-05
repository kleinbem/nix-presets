{
  pkgs,
  lib,

  nixpak,
  ...
}:

let
  # Import modular apps catalog
  sandboxedApps = import ./nixpak/apps.nix { inherit pkgs nixpak; };

  commonData = import ./code-common/settings.nix;
  extensionsCommon = import ./code-common/extensions/common.nix { inherit pkgs; };
  extensionsVSCode = import ./code-common/extensions/vscode.nix { inherit pkgs; };
  extensionsCursor = import ./code-common/extensions/cursor.nix { inherit pkgs; };

  # Helper to bundle extensions
  mkBundle =
    name: exts:
    pkgs.symlinkJoin {
      name = "${name}-extensions-bundle";
      paths = exts;
    };

  bundleAntigravity = mkBundle "antigravity" (extensionsCommon ++ extensionsVSCode); # Antigravity needs the pin too
  bundleCursor = mkBundle "cursor" (extensionsCommon ++ extensionsCursor);
  bundleWindsurf = mkBundle "windsurf" extensionsCommon;

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
    pkgs.writeShellScriptBin (lib.toLower app.name) ''
      exec ${
        pkgs."${
          if app.name == "Windsurf" then
            "windsurf"
          else if app.name == "Cursor" then
            "code-cursor-fhs"
          else
            "antigravity-fhs"
        }"
      }/bin/${
        if app.name == "Windsurf" then
          "windsurf"
        else if app.name == "Cursor" then
          "cursor"
        else
          "antigravity"
      } \
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
      # Unified Code Platform Editors
      # (Replaced by Isolated Wrappers below)

      # -- GUI Apps --
      # Unified Code Platform Editors (Isolated Wrappers)
      (mkIsolatedEditor (builtins.elemAt codeFamily 0)) # Antigravity
      (mkIsolatedEditor (builtins.elemAt codeFamily 1)) # Cursor
      (mkIsolatedEditor (builtins.elemAt codeFamily 2)) # Windsurf

      # vscode-fhs (Moved to declarative module)
      warp-terminal # Rust-based AI Terminal
      pavucontrol
      nwg-look
      mission-center # System Monitor (Task Manager)
      zathura # PDF Viewer
      imv # Image Viewer
      p7zip # Archives
      rclone-browser # GUI for Rclone
      restic-browser # GUI for Restic Backups
      restic # CLI Tool (Required for Restic Browser)
      obs-studio # Streaming/Recording Software

      # --- Communication ---
      sandboxedApps.discord
      sandboxedApps.slack
      sandboxedApps.signal-desktop

      # -- Sandboxed Apps --
      sandboxedApps.obsidian
      sandboxedApps.mpv # Nixpak (Safe)
      sandboxedApps.google-chrome-stable # Standard Profile (Renamed from google-chrome)
      sandboxedApps.google-chrome-stable-vault
      sandboxedApps.google-chrome-stable-hazard
      sandboxedApps.lmstudio # Nixpak (Safe)
      sandboxedApps.bitwarden # Nixpak (Safe) - Password Manager
      # sandboxedApps.github-desktop # Nixpak (Safe) - Code
      github-desktop # Standard (Unsafe) - Temporarily disabled sandbox for auth debugging
      chromium # Fallback (Unsafe) - Local Dev
      pkgs.brotab # Browser Automation (asked by user)
      pkgs.brave # Secure Browser (asked by user)

      # Math and Matrix stuff. Using 'octaveFull' to get the standard packages included.
      octaveFull

      # Modern LaTeX alternative. Much faster for writing docs.
      typst
      tinymist # autocompletion in VS Code/Neovim (formerly typst-lsp)
      nixd # Nix Language Server
    ];

    # Generate declarative config files for all agents
    file = lib.mkMerge (map mkConfigs codeFamily);

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
      "text/html" = [ "google-chrome-stable.desktop" ];
      "x-scheme-handler/http" = [ "google-chrome-stable.desktop" ];
      "x-scheme-handler/https" = [ "google-chrome-stable.desktop" ];
      "x-scheme-handler/about" = [ "google-chrome-stable.desktop" ];
      "x-scheme-handler/unknown" = [ "google-chrome-stable.desktop" ];
    };
  };

  # Create a custom "Fortress" launcher for BOI
  xdg.desktopEntries = {
    # Manual entries removed - now handled by nixpak apps.nix
  };

  programs.waybar.enable = true;

  systemd.user.services.rclone-gdrive-mount = {
    Unit = {
      Description = "Mount Google Drive via Rclone";
      After = [ "network-online.target" ];
    };
    Service = {
      Type = "simple";
      Environment = "PATH=/run/wrappers/bin:$PATH";
      # Ensure the mount point exists: mkdir -p ~/GoogleDrive
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p %h/GoogleDrive";
      ExecStart = ''
        ${pkgs.rclone}/bin/rclone mount gdrive: %h/GoogleDrive \
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

  systemd.user.services.rclone-onedrive-mount = {
    Unit = {
      Description = "Mount OneDrive via Rclone";
      After = [ "network-online.target" ];
    };
    Service = {
      Type = "simple";
      Environment = "PATH=/run/wrappers/bin:$PATH";
      # Ensure the mount point exists: mkdir -p ~/OneDrive
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p %h/OneDrive";
      ExecStart = ''
        ${pkgs.rclone}/bin/rclone mount onedrive: %h/OneDrive \
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
}
