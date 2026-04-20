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
        urls = [ { template = "https://www.google.ie/search?q={searchTerms}"; } ];
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
    home.packages = [
      pkgs.firefox-beta
      pkgs.firefox-devedition
    ];

    # Unify Developer Edition and Firefox profile directories declaratively
    home.file.".mozilla/firefox-dev-edition".source =
      config.lib.file.mkOutOfStoreSymlink "/home/${config.home.username}/.mozilla/firefox";

    xdg.desktopEntries = {
      # --- Hide default package launchers to avoid menu clutter ---
      firefox = {
        name = "Firefox (Default)";
        exec = "firefox-beta %u";
        settings.NoDisplay = "true";
      };
      firefox-devedition = {
        name = "Firefox Dev (Default)";
        exec = "firefox-devedition %u";
        settings.NoDisplay = "true";
      };
      firefox-beta = {
        name = "Firefox Beta (Hidden)";
        exec = "firefox-beta %u";
        settings.NoDisplay = "true";
      };

      firefox-standard = {
        name = "Firefox";
        genericName = "Web Browser";
        exec = "${lib.getExe pkgs.firefox-beta} -P standard %u";
        icon = "firefox";
        terminal = false;
        categories = [
          "Network"
          "WebBrowser"
        ];
      };
      firefox-developer = {
        name = "Firefox Developer Edition";
        genericName = "Developer Web Browser";
        exec = "${lib.getExe pkgs.firefox-devedition} -P laboratory %u";
        icon = "firefox-devedition";
        terminal = false;
        categories = [
          "Network"
          "WebBrowser"
          "Development"
        ];
      };
      firefox-vault = {
        name = "Firefox Vault";
        genericName = "Secure Browser (Beta)";
        exec = "${lib.getExe pkgs.firefox-beta} -P vault %u";
        icon = "${pkgs.adwaita-icon-theme}/share/icons/Adwaita/symbolic/status/security-high-symbolic.svg";
        terminal = false;
        categories = [
          "Network"
          "WebBrowser"
        ];
      };
    };

    programs.firefox = {
      enable = true;

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
