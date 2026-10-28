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
    freecad = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable FreeCAD MCP Server (freecad-mcp) globally for AI-driven CAD";
      };
    };
    gimp = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable GIMP 3 MCP Server (gimp3-mcp) for AI-driven photo editing";
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
        default = false;
        description = "Enable official Svelte 5 & SvelteKit documentation MCP server (@sveltejs/mcp)";
      };
    };
    buzz = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable Buzz developer MCP server (buzz-dev-mcp) for workspace AI coding agents";
      };
    };
    agentTaskQueue = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable Block's agent-task-queue MCP server (run_task / task_status):
          agents queue their expensive commands (builds, tests) so several
          sessions on one machine run them one at a time per queue.
        '';
      };
    };
    github = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable GitHub MCP server (prefer gh CLI and jj git push)";
      };
    };
    filesystem = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable filesystem MCP server (prefer native agent file tools)";
      };
    };
    memory = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable MCP knowledge graph memory server";
      };
    };
    sequentialThinking = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable sequential thinking MCP server (superseded by native model thinking)";
      };
    };
    homeAssistant = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Bridge the HA-MCP server running inside the Home Assistant
          container (ha_mcp_tools custom component, nix-presets
          containers/home-assistant.nix) into every stdio MCP client here
          via mcp-proxy. The connect URL is the credential (HA-MCP "Secret
          URL" mode), so it is read at launch from `urlFile`, never written
          into the world-readable mcp_config.json copies.
        '';
      };
      urlFile = lib.mkOption {
        type = lib.types.str;
        default = "/run/secrets/ha_mcp_url";
        description = ''
          File holding the HA-MCP connect URL (one line). A sops-nix secret
          owned by the desktop user on the host; see nix-config
          hosts/nixos-nvme/secrets.nix.
        '';
      };
    };
    servers = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            command = lib.mkOption {
              type = lib.types.str;
              description = "Program that serves MCP over stdio.";
            };
            args = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Arguments for `command`.";
            };
            env = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = { };
              description = "Environment for the server process.";
            };
          };
        }
      );
      readOnly = true;
      description = ''
        The stdio MCP servers this module registers, keyed by server name:
        the enabled set above in the `mcpServers` shape every client here
        gets. Read-only; other modules translate it for clients with another
        config format (goose extensions in nix-config's ai-agents.nix).
      '';
    };
  };

  config = lib.mkIf config.modules.mcp.enable (
    let
      freecad-mcp-src = pkgs.fetchFromGitHub {
        owner = "neka-nat";
        repo = "freecad-mcp";
        rev = "d85d8e2dad9d6deec4b36ec6826e323f68fad95e";
        sha256 = "063nnlf8rmlxc89jw40mmbmsfyb6hpxvgg0sfxjrwxgjk7yw3s59";
      };

      freecadMcpPkg = pkgs.python3.pkgs.buildPythonPackage {
        pname = "freecad-mcp";
        version = "0.1.27";
        pyproject = true;
        src = freecad-mcp-src;
        nativeBuildInputs = [ pkgs.python3.pkgs.hatchling ];
        propagatedBuildInputs = with pkgs.python3.pkgs; [
          mcp
          validators
        ];
        meta.mainProgram = "freecad-mcp";
      };

      # Two halves: the MCP server (stdio, started by the AI client) and a
      # GIMP plugin that listens on localhost:9877 once started via
      # Tools > MCP > Start MCP Server.
      # The server is our nix-packages package (held in nix-holds while it
      # needs mcp 1.x).
      gimp3McpPkg = pkgs.gimp3-mcp;

      # GIMP 3 only loads plugins that are executable and live in a folder of
      # the same name; pull the plugin out of the sdist and mark it executable.
      # nixpkgs GIMP ships no pygimp.interp, so `#!/usr/bin/env python3` would
      # pick up a Python without PyGObject and GIMP silently drops the plugin.
      # Pin the shebang to the same python+pygobject3 env GIMP's bundled
      # plugins use; GIMP's wrapper supplies GI_TYPELIB_PATH for Gimp-3.0.
      gimpPython = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);
      gimp3McpPlugin = pkgs.runCommand "gimp3-mcp-plugin" { } ''
        mkdir -p $out
        tar -xzf ${gimp3McpPkg.src} --strip-components=1 -C $out gimp3_mcp-${gimp3McpPkg.version}/gimp-mcp-plugin.py
        sed -i '1s|^#!.*|#!${gimpPython.interpreter}|' $out/gimp-mcp-plugin.py
        chmod 755 $out/gimp-mcp-plugin.py
      '';

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

      # One table for every client: the activation below copies it as
      # mcp_config.json, modules.mcp.servers exposes it for the rest.
      servers = {
        workspace-atlas = {
          command = "${pythonWithMcp}/bin/python3";
          args = [
            "-u"
            "${config.home.homeDirectory}/Develop/github.com/kleinbem/nix/tools/workspace-mcp.py"
          ];
        };
      }
      // (lib.optionalAttrs config.modules.mcp.github.enable {
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
      })
      // (lib.optionalAttrs config.modules.mcp.filesystem.enable {
        filesystem = {
          command = lib.getExe pkgs.mcp-server-filesystem;
          args = [ "${config.home.homeDirectory}/Develop" ];
        };
      })
      // (lib.optionalAttrs config.modules.mcp.memory.enable {
        memory = {
          command = lib.getExe pkgs.mcp-server-memory;
          args = [ ];
        };
      })
      // (lib.optionalAttrs config.modules.mcp.sequentialThinking.enable {
        "sequential-thinking" = {
          command = lib.getExe pkgs.mcp-server-sequential-thinking;
          args = [ ];
        };
      })
      // (lib.optionalAttrs config.modules.mcp.freecad.enable {
        freecad = {
          command = lib.getExe freecadMcpPkg;
          args = [ ];
        };
      })
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
      // (lib.optionalAttrs config.modules.mcp.gimp.enable {
        gimp = {
          command = lib.getExe gimp3McpPkg;
          args = [ ];
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
      })
      // (lib.optionalAttrs config.modules.mcp.homeAssistant.enable {
        home-assistant = {
          command = lib.getExe (
            pkgs.writeShellApplication {
              name = "home-assistant-mcp";
              runtimeInputs = [ pkgs.mcp-proxy ];
              text = ''
                url_file=${lib.escapeShellArg config.modules.mcp.homeAssistant.urlFile}
                if [ ! -r "$url_file" ]; then
                  echo "home-assistant-mcp: $url_file missing or unreadable — add ha_mcp_url to the host's sops file" >&2
                  exit 1
                fi
                exec mcp-proxy --transport streamablehttp "$(tr -d '\n' < "$url_file")"
              '';
            }
          );
          args = [ ];
        };
      })
      // (lib.optionalAttrs config.modules.mcp.buzz.enable {
        buzz = {
          command = lib.getExe pkgs.buzz-dev-mcp;
          args = [ ];
        };
      })
      // (lib.optionalAttrs config.modules.mcp.agentTaskQueue.enable {
        agent-task-queue = {
          command = lib.getExe pkgs.agent-task-queue;
          args = [ ];
        };
      });
    in
    {
      modules.mcp.servers = servers;

      home = {
        # Ensure Atlas and Python with MCP are available in the home environment
        packages = [
          (pkgs.callPackage ./atlas/default.nix { })
          freecadMcpPkg
          pythonWithMcp
        ]
        ++ lib.optional config.modules.mcp.gimp.enable pkgs.gimp3;

        file = {
          # Install FreeCAD MCP Addon declaratively
          ".local/share/FreeCAD/Mod/FreeCADMCP".source = "${freecad-mcp-src}/addon/FreeCADMCP";
        }
        // lib.optionalAttrs config.modules.mcp.gimp.enable {
          # GIMP keeps a settings folder per minor version (e.g. 3.2)
          ".config/GIMP/${lib.versions.majorMinor pkgs.gimp3.version}/plug-ins/gimp-mcp-plugin/gimp-mcp-plugin.py".source =
            "${gimp3McpPlugin}/gimp-mcp-plugin.py";
        };

        # ---------------------------------------------------------
        # Editor & AI Assistant (Claude, Antigravity, Roo-Cline, etc.) Integration
        # ---------------------------------------------------------
        # This automatically registers the MCP servers in your editors and standalone clients
        activation.setupMcpConfigs =
          let
            # Same JSON as before the option existed: the submodule fills in
            # env = { }, which no server here sets, so drop it again.
            mcpConfig = {
              mcpServers = lib.mapAttrs (
                _: server: lib.filterAttrs (name: value: !(name == "env" && value == { })) server
              ) config.modules.mcp.servers;
            };

            mcpJson = pkgs.writeText "mcp_config.json" (builtins.toJSON mcpConfig);

            # Registered but off: agents use the CLIs first and a server is
            # switched on per client when needed. Cline/Roo and Antigravity
            # read `disabled`; Claude Code gets it through its project
            # approvals below; Claude Desktop has no such key.
            mcpJsonOff = pkgs.writeText "mcp_config.json" (
              builtins.toJSON {
                mcpServers = lib.mapAttrs (_: server: server // { disabled = true; }) mcpConfig.mcpServers;
              }
            );
            mcpNames = builtins.toJSON (lib.attrNames config.modules.mcp.servers);
            claudeLocal = "${config.home.homeDirectory}/Develop/github.com/kleinbem/nix/.claude/settings.local.json";
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

            cp -f "${mcpJsonOff}" "${config.home.homeDirectory}/.gemini/antigravity/mcp_config.json"
            chmod 644 "${config.home.homeDirectory}/.gemini/antigravity/mcp_config.json"

            cp -f "${mcpJsonOff}" "${config.home.homeDirectory}/.gemini/antigravity-ide/mcp_config.json"
            chmod 644 "${config.home.homeDirectory}/.gemini/antigravity-ide/mcp_config.json"

            cp -f "${mcpJsonOff}" "${config.home.homeDirectory}/.gemini/config/mcp_config.json"
            chmod 644 "${config.home.homeDirectory}/.gemini/config/mcp_config.json"

            # Remove dangling symlink if sops previously owned it
            rm -f "${config.home.homeDirectory}/.config/Claude/claude_desktop_config.json"
            cp -f "${mcpJson}" "${config.home.homeDirectory}/.config/Claude/claude_desktop_config.json"
            chmod 644 "${config.home.homeDirectory}/.config/Claude/claude_desktop_config.json"

            cp -f "${mcpJsonOff}" "${config.home.homeDirectory}/.antigravity-ide/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json"
            chmod 644 "${config.home.homeDirectory}/.antigravity-ide/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json"

            cp -f "${mcpJsonOff}" "${config.home.homeDirectory}/.config/antigravity/data/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json"
            chmod 644 "${config.home.homeDirectory}/.config/antigravity/data/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json"

            cp -f "${mcpJsonOff}" "${config.home.homeDirectory}/.config/cursor/data/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json"
            chmod 644 "${config.home.homeDirectory}/.config/cursor/data/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json"

            cp -f "${mcpJsonOff}" "${config.home.homeDirectory}/.config/windsurf/data/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json"
            chmod 644 "${config.home.homeDirectory}/.config/windsurf/data/User/globalStorage/rooveterinaryinc.roo-cline/settings/cline_mcp_settings.json"

            cp -f "${mcpJson}" "${config.home.homeDirectory}/Develop/github.com/kleinbem/nix/.mcp.json"
            chmod 644 "${config.home.homeDirectory}/Develop/github.com/kleinbem/nix/.mcp.json"

            # Claude Code: every .mcp.json server not yet approved or refused
            # starts refused; /mcp turns one on and that choice is kept.
            claudeLocal=${lib.escapeShellArg claudeLocal}
            current='{}'
            if [ -s "$claudeLocal" ] && ${pkgs.jq}/bin/jq -e 'type == "object"' "$claudeLocal" >/dev/null 2>&1; then
              current=$(cat "$claudeLocal")
            fi
            tmp=$(mktemp)
            echo "$current" | ${pkgs.jq}/bin/jq --argjson names ${lib.escapeShellArg mcpNames} '
              (.enabledMcpjsonServers // []) as $on
              | (.disabledMcpjsonServers // []) as $off
              | .disabledMcpjsonServers = $off + ($names - $on - $off)
            ' > "$tmp"
            install -Dm644 "$tmp" "$claudeLocal"
            rm -f "$tmp"
          '';
      };
    }
  );
}
