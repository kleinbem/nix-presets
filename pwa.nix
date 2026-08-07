{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.my.pwa;

  pwaType = lib.types.submodule (
    { name, config, ... }:
    {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to enable this PWA launcher.";
        };
        name = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Display name of the application.";
        };
        url = lib.mkOption {
          type = lib.types.str;
          description = "Target URL for the PWA.";
        };
        icon = lib.mkOption {
          type = lib.types.str;
          default = "pwa-${name}";
          description = "Icon name or path for the desktop launcher.";
        };
        svg = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Raw SVG content to generate a dedicated desktop icon file.";
        };
        wmClass = lib.mkOption {
          type = lib.types.str;
          default =
            let
              # Chromium's --app= mode generates its own Wayland app_id /
              # WM_CLASS internally as `chrome-<host>__-<profile-dir>`,
              # ignoring both --class and CHROME_WRAPPER entirely — verified
              # by capturing the real `xdg_toplevel.set_app_id(...)` call via
              # WAYLAND_DEBUG=client (e.g. "chrome-github.com__-Default" for
              # https://github.com). <profile-dir> is "Default" unless
              # --profile-directory= is passed, which we never do. This must
              # match that computed value, not an arbitrary name, or GNOME
              # can't correlate the live window to this .desktop file's icon
              # and falls back to a generic one.
              hostMatch = builtins.match "https?://([^/]+).*" config.url;
              host = if hostMatch != null then builtins.head hostMatch else config.url;
            in
            "chrome-${host}__-Default";
          description = "StartupWMClass / Wayland app_id — must match Chromium's own computed `chrome-<host>__-Default` value for --app= mode, not an arbitrary name.";
        };
        extraFlags = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Individual Chromium CLI flags specifically for this PWA.";
        };
        categories = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "Network"
            "WebBrowser"
          ];
          description = "Desktop categories for app launcher menu.";
        };
      };
    }
  );
in
{
  options.my.pwa = {
    enable = lib.mkEnableOption "Declarative Chromium PWAs";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.chromium.override { enableWideVine = true; };
      description = "Chromium package to use as the PWA engine. Widevine is enabled by default so DRM-gated apps (Prime Video, Netflix, Disney+) can actually play video.";
    };
    defaultFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "--no-first-run"
        "--no-default-browser-check"
        "--enable-features=UseOzonePlatform,WaylandWindowDecorations,AudioServiceOutOfProcess"
        "--ozone-platform=wayland"
        "--enable-gpu-rasterization"
        "--enable-zero-copy"
        # Reports prefers-color-scheme: dark to every PWA's web content, so
        # sites with real dark-mode CSS (GitHub, Bitwarden vault, ...) render
        # their own dark theme instead of Chromium's crude --force-dark-mode
        # color-inversion hack.
        "--force-color-scheme=dark"
      ];
      description = "Global Chromium CLI flags applied to all PWAs.";
    };
    apps = lib.mkOption {
      type = lib.types.attrsOf pwaType;
      default = { };
      description = "Attribute set of PWA apps to register.";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.chromium = {
      enable = true;
      inherit (cfg) package;
    };

    # Built-in default apps. Defined here (as a config-level definition)
    # rather than as the option's `default`, so that consuming hosts adding
    # their own entries via `my.pwa.apps.<name> = {...}` get merged in
    # alongside these instead of silently replacing them — an option's
    # `default` is only used when *no* module provides any definition at
    # all, so any host-level definition would otherwise wipe this list.
    my.pwa.apps = {
      netflix = {
        name = "Netflix";
        url = "https://www.netflix.com";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <rect width="512" height="512" rx="96" fill="#000000"/>
            <path fill="#E50914" d="M128 64h72l74 210V64h72v384h-72l-74-210v210h-72V64z"/>
            <path fill="#B81D24" d="M274 274l74 174h72V64h-72v210z" opacity="0.4"/>
          </svg>
        '';
        extraFlags = [
          "--enable-features=VaapiVideoDecoder,VaapiVideoEncoder"
          "--ignore-gpu-blocklist"
        ];
        categories = [
          "AudioVideo"
          "Video"
          "Network"
        ];
      };
      disneyplus = {
        name = "Disney+";
        url = "https://www.disneyplus.com";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <rect width="512" height="512" rx="96" fill="#040e29"/>
            <path fill="#00d6fe" d="M256 64 C 150 64, 80 150, 80 256 C 80 362, 150 448, 256 448 C 340 448, 410 390, 428 300 H 350 C 336 340, 298 376, 256 376 C 188 376, 148 322, 148 256 C 148 190, 188 136, 256 136 C 300 136, 338 174, 350 216 H 428 C 410 126, 340 64, 256 64 Z"/>
            <path fill="#ffffff" d="M230 200 h 60 v 112 h -60 z"/>
          </svg>
        '';
        extraFlags = [
          "--enable-features=VaapiVideoDecoder,VaapiVideoEncoder"
          "--ignore-gpu-blocklist"
        ];
        categories = [
          "AudioVideo"
          "Video"
          "Network"
        ];
      };
      primevideo = {
        name = "Prime Video";
        url = "https://www.primevideo.com";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <rect width="512" height="512" rx="96" fill="#0F171E"/>
            <path fill="#ffffff" d="M208 152 L208 360 L360 256 Z"/>
            <path fill="#00A8E1" d="M120 400 C 200 448, 312 448, 392 400 C 396 397, 392 391, 387 393 C 308 424, 204 424, 125 393 C 119 391, 116 397, 120 400 Z"/>
            <path fill="#00A8E1" d="M370 386 C 386 380, 402 384, 402 392 C 402 402, 384 410, 366 406 C 362 405, 362 399, 366 396 C 372 393, 374 390, 370 386 Z"/>
          </svg>
        '';
        extraFlags = [
          "--enable-features=VaapiVideoDecoder,VaapiVideoEncoder"
          "--ignore-gpu-blocklist"
        ];
        categories = [
          "AudioVideo"
          "Video"
          "Network"
        ];
      };
      github = {
        name = "GitHub";
        url = "https://github.com";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="512" height="512">
            <rect width="24" height="24" rx="5" fill="#181717"/>
            <path fill="#ffffff" d="M12 2C6.477 2 2 6.484 2 12.017c0 4.425 2.865 8.18 6.839 9.504.5.092.682-.217.682-.483 0-.237-.008-.868-.013-1.703-2.782.605-3.369-1.343-3.369-1.343-.454-1.158-1.11-1.466-1.11-1.466-.908-.62.069-.608.069-.608 1.003.07 1.53 1.032 1.53 1.032.892 1.53 2.341 1.088 2.91.832.092-.647.35-1.088.636-1.338-2.22-.253-4.555-1.113-4.555-4.951 0-1.093.39-1.988 1.029-2.688-.103-.253-.446-1.272.098-2.65 0 0 .84-.27 2.75 1.026A9.564 9.564 0 0112 6.844c.85.004 1.705.115 2.504.337 1.909-1.296 2.747-1.027 2.747-1.027.546 1.379.202 2.398.1 2.651.64.7 1.028 1.595 1.028 2.688 0 3.848-2.339 4.695-4.566 4.943.359.309.678.92.678 1.855 0 1.338-.012 2.419-.012 2.747 0 .268.18.58.688.482A10.019 10.019 0 0022 12.017C22 6.484 17.522 2 12 2z"/>
          </svg>
        '';
        extraFlags = [ "--enable-features=DesktopPWAsLaunchHandler" ];
        categories = [
          "Development"
          "Network"
        ];
      };
    };

    # Generate managed Chromium policies (disable default browser prompts)
    # and vector SVG icon files under ~/.local/share/icons/hicolor/scalable/apps/
    home.file = {
      ".config/chromium/policies/managed/default_policy.json".text = builtins.toJSON {
        "DefaultBrowserSettingEnabled" = false;
        "FirstRunTabsEnabled" = false;
        "SystemTheme" = 1;
        "UseSystemTitleBar" = true;
      };
      ".local/share/icons/hicolor/index.theme".text = ''
        [Icon Theme]
        Name=Hicolor
        Comment=Fallback icon theme
        Hidden=true
        Directories=16x16/apps,32x32/apps,48x48/apps,128x128/apps,256x256/apps,512x512/apps,scalable/apps

        [16x16/apps]
        Size=16
        Context=Applications
        Type=Threshold

        [32x32/apps]
        Size=32
        Context=Applications
        Type=Threshold

        [48x48/apps]
        Size=48
        Context=Applications
        Type=Threshold

        [128x128/apps]
        Size=128
        Context=Applications
        Type=Threshold

        [256x256/apps]
        Size=256
        Context=Applications
        Type=Threshold

        [512x512/apps]
        Size=512
        Context=Applications
        Type=Threshold

        [scalable/apps]
        Size=128
        Context=Applications
        Type=Scalable
        MinSize=16
        MaxSize=512
      '';
      ".local/share/icons/hicolor/128x128/apps/chromium.png".source =
        "${cfg.package}/share/icons/hicolor/128x128/apps/chromium.png";
    }
    // (lib.mapAttrs' (
      id: pwa:
      lib.nameValuePair ".local/share/icons/hicolor/scalable/apps/pwa-${id}.svg" {
        text = pwa.svg;
      }
    ) (lib.filterAttrs (_: pwa: pwa.enable && pwa.svg != null) cfg.apps));

    home.packages = [
      cfg.package
    ]
    ++ (builtins.filter (x: x != null) (
      lib.mapAttrsToList (
        id: pwa:
        if pwa.enable then
          let
            allFlags = cfg.defaultFlags ++ pwa.extraFlags;
            flagsStr = lib.concatStringsSep " \\\n  " (map (f: "\"${f}\"") allFlags);
          in
          pkgs.writeShellScriptBin "pwa-${id}" ''
            exec ${cfg.package}/bin/chromium \
              --app="${pwa.url}" \
              --user-data-dir="$HOME/.local/share/pwa/${id}" \
              --class="${pwa.wmClass}" \
              ${flagsStr} \
              "$@"
          ''
        else
          null
      ) cfg.apps
    ));

    xdg.desktopEntries = lib.mapAttrs' (
      id: pwa:
      let
        iconName = if pwa.svg != null then "pwa-${id}" else pwa.icon;
      in
      lib.nameValuePair "pwa-${id}" {
        name = "${pwa.name} (PWA)";
        genericName = "${pwa.name} Web App";
        exec = "pwa-${id} %u";
        icon = iconName;
        terminal = false;
        inherit (pwa) categories;
        settings = {
          StartupNotify = "true";
          StartupWMClass = pwa.wmClass;
        };
      }
    ) (lib.filterAttrs (_: pwa: pwa.enable) cfg.apps);
  };
}
