{
  pkgs,
  config,
  lib,
  ...
}:

{
  options.modules.mcp = {
    enable = lib.mkEnableOption "MCP Servers for AI Tools";
    bambu = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable Bambu Lab 3D Printer MCP Server";
      };
      printerIp = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Bambu Lab Printer IP Address";
      };
      serialNumber = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Bambu Lab Printer Serial Number";
      };
      accessCode = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Bambu Lab Printer LAN Access Code";
      };
    };
    blender = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable Blender MCP Server for organic 3D modeling";
      };
    };
    openscad = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable OpenSCAD MCP Server for code-based CAD";
      };
    };
    svelte = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable official Svelte 5 & SvelteKit documentation MCP server (@sveltejs/mcp)";
      };
    };
  };

  config = lib.mkIf config.modules.mcp.enable (
    let
      freecad-mcp-src = pkgs.fetchFromGitHub {
        owner = "neka-nat";
        repo = "freecad-mcp";
        rev = "751974609a401660a58a1772ef16f3afbeba9ba1";
        sha256 = "1d98yrn66pyj8a436bb8yx1pcgmch6idiq4w9zq603v1x1klb3yf";
      };

      freecadMcpPkg = pkgs.python3.pkgs.buildPythonPackage {
        pname = "freecad-mcp";
        version = "0.1.24";
        pyproject = true;
        src = freecad-mcp-src;
        nativeBuildInputs = [ pkgs.python3.pkgs.hatchling ];
        propagatedBuildInputs = with pkgs.python3.pkgs; [
          mcp
          validators
        ];
        meta.mainProgram = "freecad-mcp";
      };
    in
    {
      home = {
        # Ensure Atlas and Python with MCP are available in the home environment
        packages = [
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
        file.".local/share/FreeCAD/Mod/FreeCADMCP".source = "${freecad-mcp-src}/addon/FreeCADMCP";

        # ---------------------------------------------------------
        # Editor & AI Assistant (Claude, Antigravity, Roo-Cline, etc.) Integration
        # ---------------------------------------------------------
        # This automatically registers the MCP servers in your editors and standalone clients
        activation.setupMcpConfigs =
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
              }
              // (lib.optionalAttrs config.modules.mcp.bambu.enable {
                bambu-printer = {
                  command = "${pkgs.nodejs_22}/bin/npx";
                  args = [
                    "-y"
                    "@griches/bambu-mcp"
                  ];
                  env = {
                    BAMBU_PRINTER_IP = config.modules.mcp.bambu.printerIp;
                    BAMBU_SERIAL = config.modules.mcp.bambu.serialNumber;
                    BAMBU_ACCESS_CODE = config.modules.mcp.bambu.accessCode;
                  };
                };
              })
              // (lib.optionalAttrs config.modules.mcp.blender.enable {
                blender = {
                  command = "${pkgs.nodejs_22}/bin/npx";
                  args = [
                    "-y"
                    "blender-mcp"
                  ];
                };
              })
              // (lib.optionalAttrs config.modules.mcp.openscad.enable {
                openscad = {
                  command = "${pkgs.nodejs_22}/bin/npx";
                  args = [
                    "-y"
                    "openscad-mcp-server"
                  ];
                };
              })
              // (lib.optionalAttrs config.modules.mcp.svelte.enable {
                svelte = {
                  command = "${pkgs.nodejs_22}/bin/npx";
                  args = [
                    "-y"
                    "@sveltejs/mcp"
                  ];
                };
              });
            };
            mcpJson = pkgs.writeText "mcp_config.json" (builtins.toJSON mcpConfig);
          in
          lib.hm.dag.entryAfter [ "writeBoundary" ] ''
            mkdir -p "${config.home.homeDirectory}/.gemini/antigravity"
            mkdir -p "${config.home.homeDirectory}/.gemini/antigravity-ide"
            mkdir -p "${config.home.homeDirectory}/.gemini/config"
            mkdir -p "${config.home.homeDirectory}/.config/Claude"
            mkdir -p "${config.home.homeDirectory}/.antigravity-ide/User/globalStorage/rooveterinaryinc.roo-cline/settings"
            mkdir -p "${config.home.homeDirectory}/.config/antigravity/data/User/globalStorage/rooveterinaryinc.roo-cline/settings"
            mkdir -p "${config.home.homeDirectory}/.config/cursor/data/User/globalStorage/rooveterinaryinc.roo-cline/settings"
            mkdir -p "${config.home.homeDirectory}/.config/windsurf/data/User/globalStorage/rooveterinaryinc.roo-cline/settings"

            cp -f "${mcpJson}" "${config.home.homeDirectory}/.gemini/antigravity/mcp_config.json"
            chmod 644 "${config.home.homeDirectory}/.gemini/antigravity/mcp_config.json"

            cp -f "${mcpJson}" "${config.home.homeDirectory}/.gemini/antigravity-ide/mcp_config.json"
            chmod 644 "${config.home.homeDirectory}/.gemini/antigravity-ide/mcp_config.json"

            cp -f "${mcpJson}" "${config.home.homeDirectory}/.gemini/config/mcp_config.json"
            chmod 644 "${config.home.homeDirectory}/.gemini/config/mcp_config.json"

            # Remove dangling symlink if sops previously owned it
            rm -f "${config.home.homeDirectory}/.config/Claude/claude_desktop_config.json"
            cp -f "${mcpJson}" "${config.home.homeDirectory}/.config/Claude/claude_desktop_config.json"
            chmod 644 "${config.home.homeDirectory}/.config/Claude/claude_desktop_config.json"

            cp -f "${mcpJson}" "${config.home.homeDirectory}/.antigravity-ide/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json"
            chmod 644 "${config.home.homeDirectory}/.antigravity-ide/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json"

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
  );
}
