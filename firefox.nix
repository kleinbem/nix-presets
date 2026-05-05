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
      "Obsidian" = {
        urls = [ { template = "obsidian://search?query={searchTerms}"; } ];
        icon = "https://obsidian.md/favicon.ico";
        definedAliases = [ "@obs" ];
      };
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
        exec = "firefox -P standard %u";
        icon = "firefox";
        terminal = false;
        categories = [
          "Network"
          "WebBrowser"
        ];
        mimeType = [
          "text/html"
          "text/xml"
          "application/xhtml+xml"
          "application/vnd.mozilla.xul+xml"
          "x-scheme-handler/http"
          "x-scheme-handler/https"
        ];
        settings = {
          StartupNotify = "true";
          StartupWMClass = "firefox-beta";
        };
      };
      firefox-developer = {
        name = "Firefox Developer Edition";
        genericName = "Developer Web Browser";
        exec = "firefox-devedition -P laboratory %u";
        icon = "firefox-devedition";
        terminal = false;
        categories = [
          "Network"
          "WebBrowser"
          "Development"
        ];
        mimeType = [
          "text/html"
          "text/xml"
          "application/xhtml+xml"
          "application/vnd.mozilla.xul+xml"
          "x-scheme-handler/http"
          "x-scheme-handler/https"
        ];
        settings = {
          StartupNotify = "true";
          StartupWMClass = "firefox-devedition";
        };
      };
      firefox-vault = {
        name = "Firefox Vault";
        genericName = "Secure Browser (Beta)";
        exec = "firefox -P vault %u";
        icon = "${pkgs.adwaita-icon-theme}/share/icons/Adwaita/symbolic/status/security-high-symbolic.svg";
        terminal = false;
        categories = [
          "Network"
          "WebBrowser"
        ];
        mimeType = [
          "text/html"
          "text/xml"
          "application/xhtml+xml"
          "application/vnd.mozilla.xul+xml"
          "x-scheme-handler/http"
          "x-scheme-handler/https"
        ];
        settings = {
          StartupNotify = "true";
          StartupWMClass = "firefox-beta";
        };
      };
    };

    programs.firefox = {
      enable = true;
      configPath = ".mozilla/firefox";

      nativeMessagingHosts = [ pkgs.bitwarden-desktop ];

      policies = {
        Certificates = {
          Install = [
            "/home/martin/.pki/caddy-root.crt"
            "/nix/persist/pki/internal/ca.crt"
          ];
        };
      };

      profiles = {
        # --- Profile 1: Standard (Hardened Daily Driver) ---
        standard = {
          id = 0;
          name = "standard";
          isDefault = true;
          extensions.packages = browserSettings.standardExtensions;
          settings = browserSettings.standardSettings;
          userChrome = ''
            /* High-visibility active tab highlight (Top Bar) */
            .tabbrowser-tab[selected="true"] {
              background-color: rgba(255, 255, 255, 0.1) !important;
            }
            .tab-background[selected="true"] {
              outline: 2px solid #00ddff !important;
              outline-offset: -2px !important;
            }

            /* Sidebar (Sidebery) container tweaks */
            #sidebar-header {
              background-color: #1a1a1a !important;
              color: #efefef !important;
              border-bottom: 1px solid #333 !important;
            }
            #sidebar-box {
              --sidebar-background-color: #1a1a1a !important;
            }
          '';
          search = commonSearch;
        };

        # --- Profile 2: Laboratory (AI & Power Workspace) ---
        laboratory = {
          id = 1;
          name = "laboratory";
          extensions.packages = browserSettings.laboratoryExtensions;
          settings = browserSettings.laboratorySettings;
          userChrome = ''
            /* High-visibility active tab highlight (Top Bar) */
            .tabbrowser-tab[selected="true"] {
              background-color: rgba(255, 255, 255, 0.1) !important;
            }
            .tab-background[selected="true"] {
              outline: 2px solid #ff00ff !important; /* Magenta accent for Laboratory */
              outline-offset: -2px !important;
            }

            /* Sidebar (Sidebery) container tweaks */
            #sidebar-header {
              background-color: #1a1a1a !important;
              color: #efefef !important;
              border-bottom: 1px solid #333 !important;
            }
          '';
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
