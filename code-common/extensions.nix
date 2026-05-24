{ pkgs }:

# Unified Extension Catalog for all VS Code-family editors.
# Uses nix-community/nix-vscode-extensions overlay.
# Extensions are sourced from OpenVSX (preferred for Antigravity/Windsurf)
# and VS Code Marketplace (for VS Code/Cursor exclusives).

let
  mkt = pkgs.vscode-marketplace;
in
{
  # Shared across ALL editors (Antigravity, Cursor, Windsurf, VS Code)
  common = [
    # --- NixOS Essentials ---
    mkt.mkhl.direnv
    mkt.jnoortheen.nix-ide
    mkt.tamasfe.even-better-toml

    # --- Coding & Git ---
    mkt.waderyan.gitblame
    # mkt.ms-python.python  # disabled: jedi-language-server-0.46.0 requires jedi<0.20, nixpkgs has 0.20.0

    # --- Productivity ---
    mkt.usernamehw.errorlens
    mkt.gruntfuggly.todo-tree
    mkt.shd101wyy.markdown-preview-enhanced
    mkt.yzhang.markdown-all-in-one

    # --- Infrastructure ---
    mkt.hashicorp.terraform
  ];

  # AI-specific extensions (may not be on OpenVSX — fall back to marketplace)
  ai = [
    mkt.github.copilot
    mkt.rooveterinaryinc.roo-cline
    # WAITING: temporarily disabled because the extension depends on the yanked 2.1.88 src!
    # pkgs.vscode-extensions.anthropic.claude-code
  ];

  # VS Code & Antigravity specific (copilot-chat needs a pin for compat)
  vscodeExtra = [
    mkt.github.copilot-chat
  ];

  # Cursor-specific overrides
  cursorExtra = [
    mkt.github.copilot-chat
  ];
}
