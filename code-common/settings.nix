{
  settings = {
    # --- Visuals ---
    "editor.fontFamily" = "'Fira Code', 'Droid Sans Mono', monospace";
    "editor.fontSize" = 14;
    "editor.formatOnSave" = true;
    "workbench.colorTheme" = "Default Dark Modern";
    "files.autoSave" = "afterDelay";

    # --- Nix Integration ---
    "nix.enableLanguageServer" = true;
    "nix.serverPath" = "nil";

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
