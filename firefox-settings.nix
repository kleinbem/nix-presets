{ pkgs, ... }:
let
  # Basic hygiene for all profiles
  commonSettings = {
    "datareporting.healthreport.uploadEnabled" = false;
    "toolkit.telemetry.enabled" = false;
    "browser.newtabpage.activity-stream.feeds.telemetry" = false;
    "browser.newtabpage.activity-stream.telemetry" = false;
    "extensions.pocket.enabled" = false;
    "browser.topsites.controversial.enabled" = false;
    "browser.download.panel.shown" = true;
    "browser.startup.page" = 3; # Restore previous session
    "browser.sessionstore.interval" = 5000; # Save session every 5 seconds (default is 15s)
    "browser.sessionstore.warnOnQuit" = true; # Warn before quitting to prevent accidental state loss
    "identity.fxaccounts.enabled" = false;
    "security.enterprise_roots.enabled" = true; # Trust system CA store
    "network.dns.disableIPv6" = true;
    "security.webauth.webauthn" = true;
    "signon.rememberSignons" = false; # Use Bitwarden
    "browser.formfill.enable" = false; # No autocomplete

    # --- PWA Related ---
    "browser.taskbarTabs.enabled" = true;
    "dom.installevents.enabled" = true;
    "dom.webshare.enabled" = true;
    "browser.pwa.enabled" = true;
    "browser.pwa.installer.enabled" = true;

    # --- Hardware Authentication & Linux Integration ---
    "security.webauth.u2f" = true;
    "security.webauth.webauthn_enable_usbtoken" = true;
    "widget.use-xdg-desktop-portal.file-picker" = 1; # Native Linux file picker
    "widget.use-xdg-desktop-portal.mime-handler" = 1;
    "widget.use-xdg-desktop-portal.settings" = 1;

    # --- Performance & Hardware Acceleration ---
    "media.ffmpeg.vaapi.enabled" = true; # HW video decoding
    "gfx.webrender.all" = true; # Force WebRender
    "layers.acceleration.force-enabled" = true;

    # --- Privacy & Security ---
    "network.http.referer.XOriginPolicy" = 0; # 1 breaks PayPal and cross-site logins
    "privacy.trackingprotection.cryptomining.enabled" = true;
    "privacy.trackingprotection.fingerprinting.enabled" = true;

    # --- UI Cleanliness ---
    "browser.urlbar.suggest.quicksuggest.sponsored" = false;
    "browser.newtabpage.activity-stream.showSponsored" = false;
    "browser.tabs.closeWindowWithLastTab" = false;
    "browser.translations.enable" = true;
    "browser.translations.ui.showUpsell" = true;

    # --- UI Customization ---
    "toolkit.legacyUserProfileCustomizations.stylesheets" = true;

    # --- Native Vertical Tabs (Input from Heise/Archive) ---
    "sidebar.revamp" = true;
    "sidebar.verticalTabs" = true;
    "sidebar.main.width" = 220;
  };

  commonExtensions = with pkgs.nur.repos.rycee.firefox-addons; [
    bitwarden
    ublock-origin
    privacy-badger
    darkreader
    multi-account-containers
    clearurls
    consent-o-matic
    markdownload
  ];
in
{
  # --- Level 1: Standard (Hardened Daily Driver) ---
  standardSettings = commonSettings // {
    "privacy.resistFingerprinting" = false;
    "privacy.trackingprotection.enabled" = true;
    "privacy.trackingprotection.socialtracking.enabled" = true;
    "privacy.firstparty.isolate" = false; # true breaks cross-site payment gateways like PayPal
    "dom.event.clipboardevents.enabled" = true;
    "media.peerconnection.enabled" = true;

    # --- AI Support ---
    "browser.ml.enable" = true;
    "browser.ml.chat.enabled" = true;
    "browser.ml.chat.page" = true;
    "browser.ml.chat.menu" = true;
    "pdfjs.enableAltTextModelDownload" = true;
    "pdfjs.enableGuessAltText" = true;
    "browser.tabs.groups.enabled" = true;
    "browser.labs.tab-notes.enabled" = true;
  };
  standardExtensions = commonExtensions ++ [
    pkgs.nur.repos.rycee.firefox-addons.localcdn
    pkgs.nur.repos.rycee.firefox-addons.auto-tab-discard
    pkgs.nur.repos.rycee.firefox-addons.tab-session-manager
    pkgs.nur.repos.rycee.firefox-addons.tab-stash
    pkgs.nur.repos.rycee.firefox-addons.sponsorblock
    pkgs.nur.repos.rycee.firefox-addons.languagetool
  ];

  # --- Level 2: Laboratory (AI & Power User) ---
  laboratorySettings = commonSettings // {
    "privacy.resistFingerprinting" = false; # Better compatibility for heavy apps
    "javascript.options.wasm" = true; # Required for local AI
    "browser.ml.chat.enabled" = true;
    "browser.ml.chat.sidebar" = true;
    "browser.ml.chat.provider" = "https://chat.openai.com";
    "devtools.toolbox.host" = "right"; # Better for split-view

    # --- Full AI Suite & Tab Notes ---
    "browser.ml.enable" = true;
    "browser.ml.chat.page" = true;
    "browser.ml.chat.menu" = true;
    "pdfjs.enableAltTextModelDownload" = true;
    "pdfjs.enableGuessAltText" = true;
    "browser.tabs.groups.enabled" = true;
    "browser.labs.tab-notes.enabled" = true;
  };
  laboratoryExtensions =
    commonExtensions
    ++ (with pkgs.nur.repos.rycee.firefox-addons; [
      sponsorblock
      languagetool
      tab-stash
      violentmonkey
      auto-tab-discard
      user-agent-string-switcher
    ]);

  # --- Level 3: Vault (Banking & Sensitive) ---
  vaultSettings = commonSettings // {
    "privacy.resistFingerprinting" = false;
    "network.cookie.lifetimePolicy" = 2; # Clear cookies on exit
    "privacy.sanitize.sanitizeOnShutdown" = true;
    "privacy.clearOnShutdown.cookies" = true;
    "privacy.clearOnShutdown.history" = true;
    "browser.privatebrowsing.autostart" = false;
    "network.IDN_show_punycode" = true; # Phishing protection

    # --- Explicitly Disable AI for Privacy ---
    "browser.ml.enable" = false;
    "browser.ml.chat.enabled" = false;
  };
  vaultExtensions = commonExtensions; # Sidebery removed, keeping UI minimal
}
