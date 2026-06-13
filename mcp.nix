{
  pkgs,
  config,
  lib,
  ...
}:

{
  options.modules.mcp = {
    enable = lib.mkEnableOption "MCP Servers for AI Tools";
  };

  config = lib.mkIf config.modules.mcp.enable {
    # Ensure Atlas and Python with MCP are available in the home environment
    home.packages = [
      (pkgs.callPackage ./atlas/default.nix { })
      (pkgs.python3.withPackages (
        ps: with ps; [
          mcp
          pydantic
          pydantic-core
          google-auth
          google-auth-oauthlib
          google-api-python-client
          requests
          psutil
        ]
      ))
    ];

    # Secure Claude Config
    sops.templates."Claude/claude_desktop_config.json" = {
      path = "${config.home.homeDirectory}/.config/Claude/claude_desktop_config.json";
      content =
        let
          pythonWithMcp = pkgs.python3.withPackages (
            ps: with ps; [
              mcp
              pydantic
              pydantic-core
              google-auth
              google-auth-oauthlib
              google-api-python-client
              requests
              psutil
            ]
          );
        in
        builtins.toJSON {
          mcpServers = {
            # 1. Workspace Atlas (Native command)
            workspace-atlas = {
              command = "${pythonWithMcp}/bin/python3";
              args = [
                "-u"
                "${config.home.homeDirectory}/Develop/github.com/kleinbem/nix/scripts/workspace-mcp.py"
              ];
            };

            # 2. GitHub (Secure, Short-Lived Tokens)
            # TODO: @modelcontextprotocol/server-github is the deprecated TS
            # implementation. The maintained successor is the Go binary
            # `github-mcp-server` (already in nixpkgs at 1.1.2). Migrating
            # requires changing the CLI invocation (`github-mcp-server stdio`)
            # and verifying atlas's auth wiring still passes the right env
            # vars. Tracked separately so it doesn't ride on the supply-chain
            # hardening change.
            github = {
              command = "atlas";
              args = [
                "mcp"
                "launch"
                "github"
                "${pkgs.nodejs_22}/bin/npx"
                "-y"
                "@modelcontextprotocol/server-github"
              ];
            };

            # 3. Standard Servers — pinned nixpkgs builds, no live `npx -y`
            # supply-chain path. Bumps come in via the nightly maintain.yml.
            filesystem = {
              command = lib.getExe pkgs.mcp-server-filesystem;
              args = [ "${config.home.homeDirectory}/Develop" ];
            };

            memory = {
              command = lib.getExe pkgs.mcp-server-memory;
              args = [ ];
            };

            "sequential-thinking" = {
              command = lib.getExe pkgs.mcp-server-sequential-thinking;
              args = [ ];
            };
          };
        };
    };

    # ---------------------------------------------------------
    # Roo-Cline (Editor AI) Integration
    # ---------------------------------------------------------
    # This automatically registers the MCP servers in your editors
    home.activation.setupMcpConfigs =
      let
        pythonWithMcp = pkgs.python3.withPackages (
          ps: with ps; [
            mcp
            pydantic
            pydantic-core
            google-auth
            google-auth-oauthlib
            google-api-python-client
            requests
            psutil
          ]
        );
        mcpConfig = {
          mcpServers = {
            workspace-atlas = {
              command = "${pythonWithMcp}/bin/python3";
              args = [
                "-u"
                "${config.home.homeDirectory}/Develop/github.com/kleinbem/nix/scripts/workspace-mcp.py"
              ];
            };
            github = {
              command = "atlas";
              args = [
                "mcp"
                "launch"
                "github"
                "${pkgs.nodejs_22}/bin/npx"
                "-y"
                "@modelcontextprotocol/server-github"
              ];
            };
            filesystem = {
              command = lib.getExe pkgs.mcp-server-filesystem;
              args = [ "${config.home.homeDirectory}/Develop" ];
            };
            # TODO: @google-cloud/cloud-run-mcp is not in nixpkgs yet. Live
            # `npx -y` is the supply-chain risk we're trying to eliminate.
            # Either: (a) write a buildNpmPackage derivation in nix-packages,
            # (b) drop this server if Cloud Run access isn't load-bearing, or
            # (c) accept the risk and pin to a specific version (@X.Y.Z).
            cloudrun = {
              command = "${pkgs.nodejs_22}/bin/npx";
              args = [
                "-y"
                "@google-cloud/cloud-run-mcp"
              ];
            };

            memory = {
              command = lib.getExe pkgs.mcp-server-memory;
              args = [ ];
            };

            "sequential-thinking" = {
              command = lib.getExe pkgs.mcp-server-sequential-thinking;
              args = [ ];
            };
          };
        };
        mcpJson = pkgs.writeText "mcp_config.json" (builtins.toJSON mcpConfig);
      in
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        mkdir -p "${config.home.homeDirectory}/.gemini/antigravity"
        mkdir -p "${config.home.homeDirectory}/.gemini/config"
        mkdir -p "${config.home.homeDirectory}/.config/antigravity/data/User/globalStorage/rooveterinaryinc.roo-cline/settings"
        mkdir -p "${config.home.homeDirectory}/.config/cursor/data/User/globalStorage/rooveterinaryinc.roo-cline/settings"
        mkdir -p "${config.home.homeDirectory}/.config/windsurf/data/User/globalStorage/rooveterinaryinc.roo-cline/settings"

        cp -f "${mcpJson}" "${config.home.homeDirectory}/.gemini/antigravity/mcp_config.json"
        chmod 644 "${config.home.homeDirectory}/.gemini/antigravity/mcp_config.json"

        cp -f "${mcpJson}" "${config.home.homeDirectory}/.gemini/config/mcp_config.json"
        chmod 644 "${config.home.homeDirectory}/.gemini/config/mcp_config.json"

        cp -f "${mcpJson}" "${config.home.homeDirectory}/.config/antigravity/data/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json"
        chmod 644 "${config.home.homeDirectory}/.config/antigravity/data/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json"

        cp -f "${mcpJson}" "${config.home.homeDirectory}/.config/cursor/data/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json"
        chmod 644 "${config.home.homeDirectory}/.config/cursor/data/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json"

        cp -f "${mcpJson}" "${config.home.homeDirectory}/.config/windsurf/data/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json"
        chmod 644 "${config.home.homeDirectory}/.config/windsurf/data/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json"

        cp -f "${mcpJson}" "${config.home.homeDirectory}/Develop/github.com/kleinbem/nix/.mcp.json"
        chmod 644 "${config.home.homeDirectory}/Develop/github.com/kleinbem/nix/.mcp.json"
      '';
  };
}
