{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.my.pwa;

  pwaType = lib.types.submodule ({ name, ... }: {
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
        description = "Icon name or path for the desktop launcher.";
      };
      wmClass = lib.mkOption {
        type = lib.types.str;
        default = "pwa-${name}";
        description = "StartupWMClass for taskbar grouping and window identification.";
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
  });
in
{
  options.my.pwa = {
    enable = lib.mkEnableOption "Declarative Chromium PWAs";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.chromium;
      description = "Chromium package to use as the PWA engine.";
    };
    apps = lib.mkOption {
      type = lib.types.attrsOf pwaType;
      default = {
        netflix = {
          name = "Netflix";
          url = "https://www.netflix.com";
          icon = "netflix";
          wmClass = "pwa-netflix";
          categories = [
            "AudioVideo"
            "Video"
            "Network"
          ];
        };
        disneyplus = {
          name = "Disney+";
          url = "https://www.disneyplus.com";
          icon = "disneyplus";
          wmClass = "pwa-disneyplus";
          categories = [
            "AudioVideo"
            "Video"
            "Network"
          ];
        };
        github = {
          name = "GitHub";
          url = "https://github.com";
          icon = "github";
          wmClass = "pwa-github";
          categories = [
            "Development"
            "Network"
          ];
        };
      };
      description = "Attribute set of PWA apps to register.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ] ++ (builtins.filter (x: x != null) (lib.mapAttrsToList (id: pwa:
      if pwa.enable then
        pkgs.writeShellScriptBin "pwa-${id}" ''
          exec ${cfg.package}/bin/chromium \
            --app="${pwa.url}" \
            --user-data-dir="$HOME/.local/share/pwa/${id}" \
            --class="${pwa.wmClass}" \
            "$@"
        ''
      else
        null
    ) cfg.apps));

    xdg.desktopEntries = lib.mapAttrs' (id: pwa:
      lib.nameValuePair "pwa-${id}" {
        name = "${pwa.name} (PWA)";
        genericName = "${pwa.name} Web App";
        exec = "pwa-${id} %u";
        icon = pwa.icon;
        terminal = false;
        categories = pwa.categories;
        settings = {
          StartupNotify = "true";
          StartupWMClass = pwa.wmClass;
        };
      }
    ) (lib.filterAttrs (_: pwa: pwa.enable) cfg.apps);
  };
}
