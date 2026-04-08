{
  inputs,
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.programs.zen-browser;
  browserSettings = import ./firefox-settings.nix { inherit pkgs; };
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
      zen-laboratory = {
        name = "Zen Laboratory";
        genericName = "AI Developer Browser";
        exec = "zen-beta -P laboratory %u";
        icon = "zen-browser";
        terminal = false;
        categories = [
          "Network"
          "WebBrowser"
          "Development"
        ];
      };
      zen-vault = {
        name = "Zen Vault";
        genericName = "Secure Browser";
        exec = "zen-beta -P vault %u";
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
      package = inputs.zen-browser.packages."${pkgs.stdenv.hostPlatform.system}".default;
      nativeMessagingHosts = [ pkgs.firefoxpwa ];

      profiles = {
        # --- Profile 1: Standard (Hardened Daily Driver) ---
        standard = {
          id = 0;
          name = "standard";
          isDefault = true;
          extensions.packages = browserSettings.standardExtensions;
          settings = browserSettings.standardSettings // {
            "zen.view.compact-mode" = true;
          };
        };

        # --- Profile 2: Laboratory (AI & Power Workspace) ---
        laboratory = {
          id = 1;
          name = "laboratory";
          extensions.packages = browserSettings.laboratoryExtensions;
          settings = browserSettings.laboratorySettings // {
            "zen.view.compact-mode" = true;
            "zen.view.split-view.enabled" = true;
          };
        };

        # --- Profile 3: Vault (Banking & Sensitive) ---
        vault = {
          id = 2;
          name = "vault";
          extensions.packages = browserSettings.vaultExtensions;
          settings = browserSettings.vaultSettings // {
            "zen.view.compact-mode" = true;
          };
        };
      };
    };
  };
}
