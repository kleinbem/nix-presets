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
    "identity.fxaccounts.enabled" = false;
    "network.dns.disableIPv6" = true;
    "security.webauth.webauthn" = true;
  };

  # Common extensions for ALL profiles
  commonExtensions = with pkgs.nur.repos.rycee.firefox-addons; [
    ublock-origin
    privacy-badger
    darkreader
    multi-account-containers
    bitwarden
    pwas-for-firefox
  ];
in
{
  # --- Level 1: Standard (Hardened Daily Driver) ---
  standardSettings = commonSettings // {
    "privacy.resistFingerprinting" = false;
    "privacy.trackingprotection.enabled" = true;
    "privacy.trackingprotection.socialtracking.enabled" = true;
    "privacy.firstparty.isolate" = true;
    "dom.event.clipboardevents.enabled" = true;
    "media.peerconnection.enabled" = true;
  };
  standardExtensions = commonExtensions ++ [
    pkgs.nur.repos.rycee.firefox-addons.localcdn
  ];

  # --- Level 2: Laboratory (AI & Power User) ---
  laboratorySettings = commonSettings // {
    "privacy.resistFingerprinting" = false; # Better compatibility for heavy apps
    "javascript.options.wasm" = true; # Required for local AI
    "browser.ml.chat.enabled" = true;
    "browser.ml.chat.sidebar" = true;
    "browser.ml.chat.provider" = "https://chat.openai.com";
    "devtools.toolbox.host" = "right"; # Better for split-view
  };
  laboratoryExtensions =
    commonExtensions
    ++ (with pkgs.nur.repos.rycee.firefox-addons; [
      sponsorblock
      languagetool
      sidebery
      markdownload
    ]);

  # --- Level 3: Vault (Banking & Sensitive) ---
  vaultSettings = commonSettings // {
    "privacy.resistFingerprinting" = false;
    "network.cookie.lifetimePolicy" = 2; # Clear cookies on exit
    "privacy.sanitize.sanitizeOnShutdown" = true;
    "privacy.clearOnShutdown.cookies" = true;
    "privacy.clearOnShutdown.history" = true;
    "browser.privatebrowsing.autostart" = false;
    "signon.rememberSignons" = false; # Never save passwords (use Bitwarden)
    "browser.formfill.enable" = false; # No autocomplete
    "network.IDN_show_punycode" = true; # Phishing protection
  };
  vaultExtensions = commonExtensions; # Keep minimal
}
