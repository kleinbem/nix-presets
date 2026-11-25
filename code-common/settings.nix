{
  settings = {
    # --- Visuals ---
    "editor.fontFamily" = "'Fira Code', 'Droid Sans Mono', monospace";
    "editor.fontSize" = 14;
    "editor.formatOnSave" = true;
    "workbench.colorTheme" = "Default Dark Modern";
    "files.autoSave" = "afterDelay";

    # --- Nix Integration ---
    # nil, not nixd: nixd's option providers eval the full system + HM config
    # (multi-GB per restart, retriggered by autoSave) and can thrash the host.
    "nix.enableLanguageServer" = true;
    "nix.serverPath" = "nil";
    "nix.formatterPath" = "nixfmt";
    "direnv.restart.automatic" = true;

    "nix.serverSettings" = {
      "nil" = {
        "formatting" = {
          "command" = [ "nixfmt" ];
        };
      };
    };

    # --- Todo Tree & Productivity ---
    "todo-tree.general.tags" = [
      "TODO"
      "FIXME"
      "HACK"
      "WAITING"
      "QUESTION"
      "PERF"
      "NOTE"
    ];
    "todo-tree.highlights.defaultHighlight" = {
      "type" = "text";
      "foreground" = "#ffffff";
      "borderRadius" = "2px";
    };
    "todo-tree.highlights.customHighlight" = {
      "FIXME" = {
        "foreground" = "#f44336";
        "icon" = "fire";
        "iconColour" = "#f44336";
      };
      "WAITING" = {
        "foreground" = "#ff9800";
        "icon" = "clock";
        "iconColour" = "#ff9800";
      };
      "TODO" = {
        "foreground" = "#2196f3";
        "icon" = "check";
        "iconColour" = "#2196f3";
      };
      "PERF" = {
        "foreground" = "#9c27b0";
        "icon" = "zap";
        "iconColour" = "#9c27b0";
      };
      "NOTE" = {
        "foreground" = "#4caf50";
        "icon" = "info";
        "iconColour" = "#4caf50";
      };
    };

    # --- Marketplace Fix (CRITICAL) ---
    # Forces Windsurf, Cursor, and Antigravity to use the official VS Code Marketplace
    # instead of their proprietary ones, ensuring our Nix extensions load correctly.
    "windsurf.marketplaceExtensionGalleryServiceURL" =
      "https://marketplace.visualstudio.com/_apis/public/gallery";
    "windsurf.marketplaceGalleryItemURL" = "https://marketplace.visualstudio.com/items";
    "extensions.gallery" = {
      "serviceUrl" = "https://marketplace.visualstudio.com/_apis/public/gallery";
      "cacheUrl" = "https://vscode.blob.core.windows.net/gallery/index";
      "itemUrl" = "https://marketplace.visualstudio.com/items";
    };
  };

  keybindings = [
    {
      "key" = "ctrl+shift+b";
      "command" = "workbench.action.tasks.build";
    }
  ];
}
