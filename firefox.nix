{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.programs.firefox-browser;
  browserSettings = import ./firefox-settings.nix { inherit pkgs; };
  commonSearch = {
    default = "Google.ie";
    engines = {
      "Google.ie" = {
        urls = [{ template = "https://www.google.ie/search?q={searchTerms}"; }];
        icon = "https://www.google.com/favicon.ico";
        updateInterval = 24 * 60 * 60 * 1000; # every day
        definedAliases = [ "@g" ];
      };
      "google".metaData.hidden = true;
      "bing".metaData.hidden = true;
      "ebay".metaData.hidden = true;
    };
    force = true;
  };
in
{
  options.programs.firefox-browser = {
    enable = lib.mkEnableOption "Firefox Browser (Declarative Profiles)";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.firefoxpwa ];

    xdg.desktopEntries = {
      firefox-standard = {
        name = "Firefox Standard";
        genericName = "Web Browser";
        exec = "${lib.getExe pkgs.firefox} -P standard %u";
        icon = "${pkgs.firefox}/share/icons/hicolor/128x128/apps/firefox.png";
        terminal = false;
        categories = [
          "Network"
          "WebBrowser"
        ];
      };
      firefox-laboratory = {
        name = "Firefox Laboratory";
        genericName = "AI Developer Browser";
        exec = "${lib.getExe pkgs.firefox} -P laboratory %u";
        icon = "${pkgs.firefox-devedition}/share/icons/hicolor/128x128/apps/firefox-devedition.png";
        terminal = false;
        categories = [
          "Network"
          "WebBrowser"
          "Development"
        ];
      };
      firefox-vault = {
        name = "Firefox Vault";
        genericName = "Secure Browser";
        exec = "${lib.getExe pkgs.firefox} -P vault %u";
        icon = "${pkgs.adwaita-icon-theme}/share/icons/Adwaita/symbolic/status/security-high-symbolic.svg";
        terminal = false;
        categories = [
          "Network"
          "WebBrowser"
        ];
      };

      # Hide the PWA manager from the main launcher
      firefoxpwa = {
        name = "FirefoxPWA";
        noDisplay = true;
      };
    };

    programs.firefox = {
      enable = true;
      nativeMessagingHosts = [ pkgs.firefoxpwa ];

      profiles = {
        # --- Profile 1: Standard (Hardened Daily Driver) ---
        standard = {
          id = 0;
          name = "standard";
          isDefault = true;
          extensions.packages = browserSettings.standardExtensions;
          settings = browserSettings.standardSettings;
          search = commonSearch;
        };

        # --- Profile 2: Laboratory (AI & Power Workspace) ---
        laboratory = {
          id = 1;
          name = "laboratory";
          extensions.packages = browserSettings.laboratoryExtensions;
          settings = browserSettings.laboratorySettings;
          search = commonSearch;
        };

        # --- Profile 3: Vault (Banking & Sensitive) ---
        vault = {
          id = 2;
          name = "vault";
          extensions.packages = browserSettings.vaultExtensions;
          settings = browserSettings.vaultSettings;
          search = commonSearch;
        };
      };
    };
  };
}
