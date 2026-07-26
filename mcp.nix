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

  config = lib.mkIf config.modules.mcp.enable (
    let
      freecad-mcp-src = pkgs.fetchFromGitHub {
        owner = "neka-nat";
        repo = "freecad-mcp";
        rev = "4c3f2eff96f22f179946a1ecaf46bb50f2ac87ae";
        sha256 = "0gx43xdvamk654d9xw0gq86pq0j059aw0gfj72yzxyqs755585x2";
      };

      freecadMcpPkg = pkgs.python3.pkgs.buildPythonPackage {
        pname = "freecad-mcp";
        version = "0.1.19";
        pyproject = true;
        src = freecad-mcp-src;
        nativeBuildInputs = [ pkgs.python3.pkgs.hatchling ];
        propagatedBuildInputs = with pkgs.python3.pkgs; [ mcp validators ];
        meta.mainProgram = "freecad-mcp";
      };
    in
    {
      # Ensure Atlas and Python with MCP are available in the home environment
    home.packages = [
      (pkgs.callPackage ./atlas/default.nix { })
      freecadMcpPkg
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

    # Install FreeCAD MCP Addon declaratively
    home.file.".local/share/FreeCAD/Mod/FreeCADMCP".source = "${freecad-mcp-src}/addon/FreeCADMCP";
    
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
                "${config.home.homeDirectory}/Develop/github.com/kleinbem/nix/tools/workspace-mcp.py"
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

            freecad = {
              command = lib.getExe freecadMcpPkg;
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
                "${config.home.homeDirectory}/Develop/github.com/kleinbem/nix/tools/workspace-mcp.py"
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

            freecad = {
              command = lib.getExe freecadMcpPkg;
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
  });
}
