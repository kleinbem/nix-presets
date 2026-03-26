{
  inputs,
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.programs.zen-browser;
  # Common extensions for all profiles
  commonExtensions = with pkgs.nur.repos.rycee.firefox-addons; [
    ublock-origin
    privacy-badger
    darkreader
    multi-account-containers
    bitwarden
  ];

  # Arkenfox-style hardening (from previous config)
  commonSettings = {
    # --- PRIVACY & TRACKING ---
    "privacy.resistFingerprinting" = true;
    "privacy.trackingprotection.enabled" = true;
    "privacy.trackingprotection.socialtracking.enabled" = true;
    "privacy.firstparty.isolate" = true;

    # --- SECURITY BITS ---
    "dom.event.clipboardevents.enabled" = false;
    "media.peerconnection.enabled" = false;
    "network.dns.disableIPv6" = true;

    # --- CLEANUP (TELEMETRY & BLOAT) ---
    "datareporting.healthreport.uploadEnabled" = false;
    "toolkit.telemetry.enabled" = false;
    "browser.newtabpage.activity-stream.feeds.telemetry" = false;
    "browser.newtabpage.activity-stream.telemetry" = false;
    "extensions.pocket.enabled" = false;
    "browser.topsites.controversial.enabled" = false;

    # --- CONVENIENCE & UI ---
    "browser.download.panel.shown" = true;
    "browser.startup.page" = 3;
    "identity.fxaccounts.enabled" = false;
    "zen.view.compact-mode" = true;
  };
in
{
  options.programs.zen-browser = {
    enable = lib.mkEnableOption "Zen Browser (Declarative Profiles)";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.firefoxpwa ];

    # Unify Zen and Firefox profile directories declaratively
    home.file.".config/zen".source =
      config.lib.file.mkOutOfStoreSymlink "/home/${config.home.username}/.mozilla/firefox";

    xdg.desktopEntries = {
      # Hide the default package entry to avoid menu clutter
      zen-beta = {
        name = "Zen Browser (Core)";
        exec = "zen-beta %u";
        icon = "zen-browser";
        settings.NoDisplay = "true";
      };

      zen-default = {
        name = "Zen Browser";
        genericName = "Web Browser";
        exec = "zen-beta %u";
        icon = "zen-browser";
        terminal = false;
        categories = [
          "Network"
          "WebBrowser"
        ];
        mimeType = [
          "text/html"
          "text/xml"
          "application/xhtml+xml"
          "application/xml"
          "application/rss+xml"
          "application/rdf+xml"
          "image/gif"
          "image/jpeg"
          "image/png"
          "x-scheme-handler/http"
          "x-scheme-handler/https"
          "x-scheme-handler/ftp"
        ];
      };
      zen-ai = {
        name = "Zen AI Workspace";
        genericName = "AI Developer Browser";
        exec = "zen-beta -P ai %u";
        icon = "zen-browser";
        terminal = false;
        categories = [
          "Network"
          "WebBrowser"
          "Development"
        ];
      };
      zen-pwa = {
        name = "Zen PWA Engine";
        genericName = "PWA Browser";
        exec = "zen-beta -P pwa %u";
        icon = "zen-browser";
        terminal = false;
        categories = [
          "Network"
          "WebBrowser"
        ];
      };
    };

    programs.firefox = {
      enable = true;
      package = inputs.zen-browser.packages."${pkgs.system}".default;
      nativeMessagingHosts = [ pkgs.firefoxpwa ];

      profiles = {
        # --- Profile 1: Default (Hardened) ---
        default = {
          id = 0;
          name = "default";
          isDefault = true;
          extensions.packages = commonExtensions;
          settings = commonSettings;
        };

        # --- Profile 2: AI (Workspace) ---
        ai = {
          id = 1;
          name = "ai";
          extensions.packages = commonExtensions;
          settings = commonSettings // {
            "browser.ml.chat.enabled" = true;
            "browser.ml.chat.sidebar" = true;
            "browser.ml.chat.provider" = "https://chat.openai.com";
            "zen.view.split-view.enabled" = true;
            "javascript.options.wasm" = true;
          };
        };

        # --- Profile 3: PWA (Dedicated Bridge) ---
        pwa = {
          id = 2;
          name = "pwa";
          extensions.packages = commonExtensions ++ [
            pkgs.nur.repos.rycee.firefox-addons.pwas-for-firefox
          ];
          settings = commonSettings;
        };
      };
    };
  };
}
