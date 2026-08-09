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
        # Chromium on Linux doesn't pick up the desktop's dark-mode
        # preference on its own (long-standing upstream bug), so PWA windows
        # default to light. --force-color-scheme=dark isn't a real Chromium
        # switch (verified against upstream chrome/ui_base switches source —
        # it's silently ignored), which is why this wasn't working. The real
        # switch is --force-dark-mode, which also flips prefers-color-scheme
        # to dark for web content, so sites with real dark-mode CSS (GitHub,
        # Bitwarden vault, ...) render their own dark theme rather than a
        # color-inversion hack.
        "--force-dark-mode"
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

    # Unlike Firefox (nix-presets/firefox.nix, which trusts these same two
    # files via its own `policies.Certificates.Install`), Chromium on Linux
    # doesn't read the system OpenSSL bundle (security.pki.certificateFiles)
    # or a per-app policy for custom root CAs — it verifies against the
    # shared NSS database at ~/.pki/nssdb, importable only via `certutil`.
    # Without this, every *.kleinbem.dev PWA served through Caddy's
    # self-signed `tls internal` cert (homelab dashboard, n8n, code-server,
    # Open WebUI, Ente Auth) shows a cert-warning interstitial in its app
    # window. Idempotent: reinitializes the DB only if missing, and
    # replaces any stale cert under the same nickname before re-adding.
    home.activation.trustFleetInternalCas = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      let
        certutil = "${pkgs.nss.tools}/bin/certutil";
        nssdb = "sql:$HOME/.pki/nssdb";
        importCert = nickname: certFile: ''
          if [ -f "${certFile}" ]; then
            ${certutil} -D -d "${nssdb}" -n "${nickname}" 2>/dev/null || true
            ${certutil} -A -d "${nssdb}" -t "C,," -n "${nickname}" -i "${certFile}"
          fi
        '';
      in
      ''
        mkdir -p "$HOME/.pki"
        if [ ! -f "$HOME/.pki/nssdb/cert9.db" ]; then
          ${certutil} -N -d "${nssdb}" --empty-password
        fi
        ${importCert "Caddy Internal CA" "$HOME/.pki/caddy-root.crt"}
        ${importCert "Kleinbem Internal CA" "/nix/persist/pki/internal/ca.crt"}
      ''
    );

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
      gemini = {
        name = "Gemini";
        url = "https://gemini.google.com";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <defs>
              <linearGradient id="geminiGrad" x1="0%" y1="0%" x2="100%" y2="100%">
                <stop offset="0%" stop-color="#4285F4"/>
                <stop offset="50%" stop-color="#9B72CB"/>
                <stop offset="100%" stop-color="#D96570"/>
              </linearGradient>
            </defs>
            <rect width="512" height="512" rx="96" fill="#131314"/>
            <path fill="url(#geminiGrad)" d="M256 88 C 266 176, 336 246, 424 256 C 336 266, 266 336, 256 424 C 246 336, 176 266, 88 256 C 176 246, 246 176, 256 88 Z"/>
          </svg>
        '';
        categories = [
          "Network"
          "Utility"
        ];
      };
      youtube = {
        name = "YouTube";
        url = "https://www.youtube.com";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <rect width="512" height="512" rx="96" fill="#FF0000"/>
            <path fill="#ffffff" d="M204 176 L204 336 L348 256 Z"/>
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
      youtubemusic = {
        name = "YouTube Music";
        url = "https://music.youtube.com";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <defs>
              <linearGradient id="ytmGrad" x1="0%" y1="0%" x2="100%" y2="100%">
                <stop offset="0%" stop-color="#FF0000"/>
                <stop offset="100%" stop-color="#FF9900"/>
              </linearGradient>
            </defs>
            <rect width="512" height="512" rx="96" fill="#030303"/>
            <circle cx="256" cy="256" r="180" fill="url(#ytmGrad)"/>
            <circle cx="256" cy="256" r="180" fill="none" stroke="#ffffff" stroke-width="14"/>
            <path fill="#ffffff" d="M228 190 L228 322 L340 256 Z"/>
          </svg>
        '';
        extraFlags = [
          "--enable-features=VaapiVideoDecoder,VaapiVideoEncoder"
          "--ignore-gpu-blocklist"
        ];
        categories = [
          "AudioVideo"
          "Audio"
          "Network"
        ];
      };
      amazonie = {
        name = "Amazon";
        url = "https://www.amazon.ie";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <rect width="512" height="512" rx="96" fill="#131A22"/>
            <rect x="140" y="160" width="232" height="180" rx="12" fill="#FF9900"/>
            <rect x="140" y="160" width="232" height="40" rx="12" fill="#E88A00"/>
            <path fill="none" stroke="#131A22" stroke-width="10" d="M140 160 L256 220 L372 160"/>
            <path fill="#FF9900" d="M120 380 C 200 430, 320 430, 400 380 C 405 377, 410 384, 405 388 C 320 444, 200 444, 115 388 C 110 384, 115 377, 120 380 Z"/>
            <path fill="#FF9900" d="M372 358 C 392 350, 412 356, 410 368 C 408 382, 386 392, 366 386 C 360 384, 360 376, 366 372 C 374 368, 378 364, 372 358 Z"/>
          </svg>
        '';
      };
      whatsapp = {
        name = "WhatsApp";
        url = "https://web.whatsapp.com";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <rect width="512" height="512" rx="96" fill="#25D366"/>
            <path fill="#ffffff" d="M256 130c-70 0-127 57-127 127 0 22 6 43 16 62l-17 62 64-17c18 9 38 14 64 14 70 0 127-57 127-127s-57-121-127-121z"/>
            <path fill="#25D366" d="M256 148c-59 0-107 48-107 107 0 19 5 38 14 54l3 5-10 37 38-10 5 3c15 8 33 13 51 13 59 0 107-48 107-107 0-59-42-102-101-102z"/>
            <path fill="#ffffff" d="M210 190c-4-8-8-8-12-8-3 0-7 0-11 4-4 4-15 15-15 36 0 21 15 41 17 44 2 3 30 46 74 64 37 15 44 12 52 11 8-1 25-10 29-20 4-10 4-18 3-20-1-2-4-3-8-5-4-2-25-12-29-14-4-1-6-2-9 2-3 4-10 14-13 17-2 2-5 3-9 1-4-2-16-6-31-19-11-10-19-22-21-26-2-4 0-6 2-8 2-2 4-5 6-7 2-2 3-4 4-6 1-2 1-4 0-6-1-2-9-22-13-30z"/>
          </svg>
        '';
        categories = [
          "Network"
          "InstantMessaging"
          "Chat"
        ];
      };
      gmail = {
        name = "Gmail";
        url = "https://mail.google.com";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <rect width="512" height="512" rx="96" fill="#ffffff"/>
            <path fill="#4285F4" d="M96 180 h320 v170 a20 20 0 0 1 -20 20 h-280 a20 20 0 0 1 -20 -20 z"/>
            <path fill="#EA4335" d="M96 180 h320 v10 L256 320 96 190 Z"/>
            <path fill="#FBBC05" d="M96 180 v170 l130 -100 -40 -30 z" opacity="0.85"/>
            <path fill="#34A853" d="M416 180 v170 l-130 -100 40 -30 z" opacity="0.85"/>
          </svg>
        '';
        categories = [
          "Network"
          "Email"
        ];
      };
      googlecalendar = {
        name = "Google Calendar";
        url = "https://calendar.google.com";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <rect width="512" height="512" rx="96" fill="#ffffff"/>
            <rect x="96" y="140" width="320" height="280" rx="16" fill="#ffffff" stroke="#dadce0" stroke-width="6"/>
            <rect x="96" y="140" width="320" height="70" fill="#4285F4"/>
            <rect x="96" y="210" width="106" height="106" fill="#EA4335"/>
            <rect x="310" y="210" width="106" height="106" fill="#34A853"/>
            <rect x="96" y="317" width="106" height="103" fill="#FBBC05"/>
            <rect x="310" y="317" width="106" height="103" fill="#4285F4"/>
            <text x="256" y="305" font-family="sans-serif" font-size="90" font-weight="bold" fill="#4285F4" text-anchor="middle">31</text>
          </svg>
        '';
        categories = [
          "Network"
          "Calendar"
        ];
      };
      googlephotos = {
        name = "Google Photos";
        url = "https://photos.google.com";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <rect width="512" height="512" rx="96" fill="#ffffff"/>
            <path fill="#4285F4" d="M256 96 a80 80 0 0 1 80 80 v80 h-80 z"/>
            <path fill="#EA4335" d="M416 256 a80 80 0 0 1 -80 80 h-80 v-80 z"/>
            <path fill="#FBBC04" d="M256 416 a80 80 0 0 1 -80 -80 v-80 h80 z"/>
            <path fill="#34A853" d="M96 256 a80 80 0 0 1 80 -80 h80 v80 z"/>
          </svg>
        '';
        categories = [
          "Network"
          "Photography"
        ];
      };
      googlemaps = {
        name = "Google Maps";
        url = "https://maps.google.com";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <rect width="512" height="512" rx="96" fill="#ffffff"/>
            <path fill="#34A853" d="M90 132 L186 96 V400 L90 436 Z"/>
            <path fill="#4285F4" d="M186 96 L326 132 V436 L186 400 Z"/>
            <path fill="#FBBC04" d="M326 132 L422 96 V400 L326 436 Z"/>
            <path fill="#EA4335" d="M256 190 c-34 0-62 28-62 62 0 46 62 118 62 118s62-72 62-118c0-34-28-62-62-62z"/>
            <circle cx="256" cy="252" r="24" fill="#ffffff"/>
          </svg>
        '';
        categories = [
          "Network"
          "Maps"
        ];
      };
      homeassistant = {
        name = "Home Assistant";
        # hass-pi container's cbr0 address (matches the generic launcher
        # `modules.service-launchers` generates from myInventory.network.nodes.home-assistant
        # in nix-config/users/martin/home.nix — kept consistent with that source of truth).
        url = "http://10.85.49.10:8123";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <rect width="512" height="512" rx="96" fill="#ffffff"/>
            <path fill="#18BCF2" d="M256 100 L432 240 h-40 v160 h-100 v-110 h-72 v110 h-100 v-160 h-40 z"/>
          </svg>
        '';
        categories = [
          "Network"
          "Utility"
        ];
      };
      grafana = {
        name = "Grafana";
        # monitoring container's cbr0 address on mac-mini, port 3000 — the
        # container's actual `server.http_port` (nix-presets/containers/monitoring.nix).
        # NOTE: myInventory.network.nodes.monitoring.externalPort is 3001, which nothing
        # actually listens on (verified against monitoring.nix and mac-mini/default.nix),
        # so the generic `service-launchers` desktop entry for this one is likely broken —
        # worth fixing in inventory.nix separately.
        url = "http://10.85.50.2:3000";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <defs>
              <linearGradient id="grafanaGrad" x1="0%" y1="0%" x2="0%" y2="100%">
                <stop offset="0%" stop-color="#F7C331"/>
                <stop offset="100%" stop-color="#F55F17"/>
              </linearGradient>
            </defs>
            <rect width="512" height="512" rx="96" fill="#161719"/>
            <path fill="url(#grafanaGrad)" d="M300 70 c20 40 -10 60 -10 100 c0 20 20 30 40 20 c10 60 -30 120 -100 120 c-70 0-120-55-110-125 c5-40 30-60 50-90 c-10 30 5 55 25 55 c15 0 25-15 20-35 c-10-40 20-60 85-45z"/>
          </svg>
        '';
        categories = [
          "Network"
          "Monitor"
        ];
      };
      homelab = {
        name = "Homelab Dashboard";
        # nix-presets/containers/dashboard is a hand-rolled static nginx page
        # (no prefers-color-scheme CSS at all) — relies entirely on
        # Chromium's --force-dark-mode heuristic repaint, not a native
        # dark/system toggle, since the app has neither.
        url = "https://home.kleinbem.dev";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <rect width="512" height="512" rx="96" fill="#0f172a"/>
            <rect x="96" y="96" width="130" height="130" rx="16" fill="#38bdf8"/>
            <rect x="286" y="96" width="130" height="130" rx="16" fill="#818cf8"/>
            <rect x="96" y="286" width="130" height="130" rx="16" fill="#34d399"/>
            <rect x="286" y="286" width="130" height="130" rx="16" fill="#fbbf24"/>
          </svg>
        '';
        categories = [
          "Network"
          "Utility"
        ];
      };
      n8n = {
        name = "n8n";
        url = "https://n8n.kleinbem.dev";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <rect width="512" height="512" rx="96" fill="#1A1A1A"/>
            <circle cx="140" cy="180" r="34" fill="#FF6D5A"/>
            <circle cx="140" cy="332" r="34" fill="#FF6D5A"/>
            <circle cx="372" cy="256" r="34" fill="#FF6D5A"/>
            <path
              stroke="#FF6D5A"
              stroke-width="14"
              fill="none"
              d="M140 180 L140 332 M140 256 L372 256"
            />
          </svg>
        '';
        categories = [
          "Network"
          "Development"
        ];
      };
      codeserver = {
        name = "code-server";
        url = "https://code.kleinbem.dev";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <rect width="512" height="512" rx="96" fill="#1e1e1e"/>
            <path
              fill="#0098FF"
              d="M362 70 L180 240 L90 170 L60 190 L150 256 L60 322 L90 342 L180 272 L362 442 L452 402 V110 Z M362 168 V344 L230 256 Z"
            />
          </svg>
        '';
        categories = [
          "Development"
          "IDE"
          "Network"
        ];
      };
      openwebui = {
        name = "Open WebUI";
        url = "https://chat.kleinbem.dev";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <rect width="512" height="512" rx="96" fill="#0b0f19"/>
            <circle cx="256" cy="226" r="130" fill="none" stroke="#ffffff" stroke-width="26"/>
            <path fill="#ffffff" d="M190 330 L150 400 L230 350 Z"/>
          </svg>
        '';
        categories = [
          "Network"
          "Utility"
        ];
      };
      paperless = {
        name = "Paperless-ngx";
        # Not proxied by Caddy (per inventory.nix) — reached directly on its
        # NASbook container address.
        url = "http://10.85.47.131:28981";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <rect width="512" height="512" rx="96" fill="#ffffff"/>
            <rect x="140" y="90" width="180" height="240" rx="12" fill="#8bc34a"/>
            <rect x="180" y="140" width="200" height="240" rx="12" fill="#4caf50"/>
            <rect x="216" y="180" width="100" height="10" rx="4" fill="#ffffff"/>
            <rect x="216" y="205" width="130" height="10" rx="4" fill="#ffffff"/>
            <rect x="216" y="230" width="90" height="10" rx="4" fill="#ffffff"/>
          </svg>
        '';
        categories = [
          "Network"
          "Office"
        ];
      };
      syncthing = {
        name = "Syncthing";
        # Container address on the Main Workstation's bridge (matches the
        # generic service-launchers entry, myInventory.network.nodes.syncthing).
        url = "http://10.85.46.127:8384";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <rect width="512" height="512" rx="96" fill="#0b3a3f"/>
            <path
              fill="none"
              stroke="#0aa3a3"
              stroke-width="36"
              stroke-linecap="round"
              d="M356 176 a140 140 0 1 0 20 100"
            />
            <path fill="#0aa3a3" d="M340 130 l60 30 l-20 65 z"/>
          </svg>
        '';
        categories = [
          "Network"
          "FileTransfer"
        ];
      };
      netdata = {
        name = "Netdata";
        url = "http://10.85.46.122:19999";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <rect width="512" height="512" rx="96" fill="#0d1117"/>
            <path
              fill="none"
              stroke="#00d67a"
              stroke-width="20"
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M80 300 h80 l40 -120 l60 180 l40 -140 l30 80 h100"
            />
          </svg>
        '';
        categories = [
          "Network"
          "Monitor"
        ];
      };
      enteauth = {
        name = "Ente Auth";
        url = "https://auth.kleinbem.dev";
        svg = ''
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
            <rect width="512" height="512" rx="96" fill="#7c3aed"/>
            <rect x="176" y="230" width="160" height="130" rx="16" fill="#ffffff"/>
            <path fill="none" stroke="#ffffff" stroke-width="26" d="M206 230 v-40 a50 50 0 0 1 100 0 v40"/>
            <circle cx="256" cy="290" r="18" fill="#7c3aed"/>
            <rect x="246" y="300" width="20" height="40" rx="8" fill="#7c3aed"/>
          </svg>
        '';
        categories = [
          "Network"
          "Security"
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
