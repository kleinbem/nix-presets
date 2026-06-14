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

            # 2. GitHub (Secure, Short-Lived Tokens via atlas)
            # Atlas mints a 1h installation token from the App credentials
            # and exports it as GITHUB_PERSONAL_ACCESS_TOKEN; the Go binary
            # github-mcp-server (nixpkgs 1.1.2) reads the same env var. The
            # deprecated TS package @modelcontextprotocol/server-github was
            # retired here as part of the live-npx supply-chain cleanup.
            github = {
              command = "atlas";
              args = [
                "mcp"
                "launch"
                "github"
                (lib.getExe pkgs.github-mcp-server)
                "stdio"
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
                (lib.getExe pkgs.github-mcp-server)
                "stdio"
              ];
            };
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
