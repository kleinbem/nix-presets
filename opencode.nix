{
  pkgs,
  config,
  lib,
  ...
}:

let
  # The Bridge Script: Allows Windsurf/Cursor to run OpenCode as an MCP server
  # It wraps the execution in nix-ld to ensure auth binaries work.
  opencode-mcp-script = pkgs.writeShellScriptBin "opencode-mcp" ''
    export NIX_LD_LIBRARY_PATH=${
      lib.makeLibraryPath (
        with pkgs;
        [
          stdenv.cc.cc.lib
          zlib
          openssl
          icu
          libuv
        ]
      )
    }
    export NIX_LD=${pkgs.stdenv.cc.libc}/lib/ld-linux-x86-64.so.2

    # Run the MCP tool via npx (standard for OpenCode MCP wrappers)
    # We use -y to skip install prompts
    exec ${pkgs.nodejs_22}/bin/npx -y github:frap129/opencode-mcp-tool
  '';

in
{
  options.modules.opencode = {
    enable = lib.mkEnableOption "OpenCode AI Agent";
  };

  config = lib.mkIf config.modules.opencode.enable {

    # 1. Install Packages & Configure Environment
    home = {
      packages = with pkgs; [
        nodejs_22 # Runtime for OpenCode
        opencode-mcp-script # Our custom bridge script
      ];

      # 1.5. Configure npm to use a writable directory
      sessionVariables = {
        NPM_CONFIG_PREFIX = "${config.home.homeDirectory}/.npm-global";
      };

      sessionPath = [
        "${config.home.homeDirectory}/.npm-global/bin"
      ];

      # 2. Install OpenCode (Imperative is safest for self-updating CLI tools)
      # We add a shell alias to help install/update it easily
      shellAliases = {
        update-opencode = "mkdir -p $HOME/.npm-global && npm install -g opencode-ai --prefix $HOME/.npm-global";
      };
    };

    # Ensure Home Manager session variables are loaded in interactive shells
    # This fixes the PATH issue without requiring a full logout/login
    # Ensure npm binaries are in PATH for interactive shells
    programs.bash.initExtra = ''
      export NPM_CONFIG_PREFIX="${config.home.homeDirectory}/.npm-global"
      export PATH="${config.home.homeDirectory}/.npm-global/bin:$PATH"
    '';

    # 3. Configure OpenCode (The "Safe" Paid Gemini Setup)
    xdg.configFile."opencode/opencode.json".text = builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";

      # The safe plugin for your paid subscription
      "plugin" = [ "opencode-gemini-auth" ];

      "system_prompt" =
        "You are my coding assistant on NixOS. When writing code comments, write them in the first person ('I') as if I (the user) wrote them myself (e.g., 'I chose this list comprehension for speed'). All output must be in Markdown. Do not wrap markdown in code blocks.";

      "mcp" = {
        "local_tools" = {
          "command" = "npx";
          "args" = [
            "-y"
            "@modelcontextprotocol/server-filesystem"
            "${config.home.homeDirectory}"
          ];
        };
      };

      "provider" = {
        "google" = {
          "models" = {
            "gemini-2.0-flash-thinking-exp-01-21" = {
              "name" = "Gemini 2.0 Flash Thinking";
              "limit" = {
                "context" = 1000000;
                "output" = 65536;
              };
            };
            "gemini-exp-1206" = {
              "name" = "Gemini Exp 1206";
              "limit" = {
                "context" = 2000000;
                "output" = 8192;
              };
            };
          };
        };
      };
    };
  };
}
