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

    googleApiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/gemini_api_key";
      description = ''
        File holding a Gemini API key for the Google provider. OpenCode reads it
        at runtime, so the key stays out of the store. Null: no key configured.
      '';
    };
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
    xdg.configFile."opencode/opencode.json".text = builtins.toJSON (
      {
        "$schema" = "https://opencode.ai/config.json";

        instructions = [ "${config.xdg.configHome}/opencode/instructions.md" ];

        # The -latest aliases follow Google's current models.
        model = "google/gemini-pro-latest";
        small_model = "google/gemini-flash-latest";
      }
      # Consumer Gemini plans can't use Gemini CLI OAuth any more, so the native
      # provider gets an API key.
      // lib.optionalAttrs (config.modules.opencode.googleApiKeyFile != null) {
        providers.google.settings.apiKey = "{file:${config.modules.opencode.googleApiKeyFile}}";
      }
    );
  };
}
