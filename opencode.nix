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
        opencode # Real nixpkgs package — a genuine binary on PATH, required
        # for herdr's `opencode` integration to have anything to launch/attach.
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
    };

    xdg.configFile."opencode/instructions.md".text = ''
      You are my coding assistant on NixOS.

      A code comment says why the code is this way, in 1-3 lines. History, dates,
      debugging stories and alternatives tried go in the commit message, not the file.

      All output must be in Markdown. Do not wrap markdown in code blocks.
    '';

    # OpenCode 2.x config schema: https://opencode.ai/config.json
    xdg.configFile."opencode/opencode.json".text = builtins.toJSON {
      "$schema" = "https://opencode.ai/config.json";

      # Gemini through the paid subscription. 2.x is the first release OpenCode 2
      # can load. no-link: unpinned, it resolves to a leftover OpenCode 1 copy in
      # ~/.cache/opencode/node_modules (local state, not an upstream bug).
      plugins = [ "opencode-gemini-auth@2.0.1" ];

      instructions = [ "${config.xdg.configHome}/opencode/instructions.md" ];

      # The -latest aliases follow Google's current models.
      model = "google/gemini-pro-latest";
      small_model = "google/gemini-flash-latest";

      mcp.servers.local_tools = {
        type = "local";
        command = [
          "${pkgs.nodejs_22}/bin/npx"
          "-y"
          "@modelcontextprotocol/server-filesystem"
          config.home.homeDirectory
        ];
      };
    };
  };
}
