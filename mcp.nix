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

    sops.secrets = {
      github_app_id = { };
      github_app_installation_id = { };
      github_app_private_key = { };
    };

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

            # 3. Standard Servers
            filesystem = {
              command = "${pkgs.nodejs_22}/bin/npx";
              args = [
                "-y"
                "@modelcontextprotocol/server-filesystem"
                "${config.home.homeDirectory}/Develop"
              ];
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
              command = "${pkgs.nodejs_22}/bin/npx";
              args = [
                "-y"
                "@modelcontextprotocol/server-filesystem"
                "${config.home.homeDirectory}/Develop"
              ];
            };
            cloudrun = {
              command = "${pkgs.nodejs_22}/bin/npx";
              args = [
                "-y"
                "@google-cloud/cloud-run-mcp"
              ];
            };
          };
        };
        mcpJson = pkgs.writeText "mcp_config.json" (builtins.toJSON mcpConfig);
      in
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        mkdir -p "${config.home.homeDirectory}/.gemini/antigravity"
        mkdir -p "${config.home.homeDirectory}/.config/antigravity/data/User/globalStorage/rooveterinaryinc.roo-cline/settings"
        mkdir -p "${config.home.homeDirectory}/.config/cursor/data/User/globalStorage/rooveterinaryinc.roo-cline/settings"
        mkdir -p "${config.home.homeDirectory}/.config/windsurf/data/User/globalStorage/rooveterinaryinc.roo-cline/settings"

        cp -f "${mcpJson}" "${config.home.homeDirectory}/.gemini/antigravity/mcp_config.json"
        chmod 644 "${config.home.homeDirectory}/.gemini/antigravity/mcp_config.json"

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
