{ pkgs, config, ... }:

{
  # Ensure Atlas is available in the home environment
  home.packages = [
    (pkgs.callPackage ./atlas/default.nix { })
  ];

  sops.secrets = {
    github_app_id = { };
    github_app_installation_id = { };
    github_app_private_key = { };
    brave_api_key = { };
  };

  # Secure Claude Config
  sops.templates."Claude/claude_desktop_config.json" = {
    path = "${config.home.homeDirectory}/.config/Claude/claude_desktop_config.json";
    content = builtins.toJSON {
      mcpServers = {
        # 1. Workspace Atlas (Native command)
        workspace-atlas = {
          command = "atlas";
          args = [
            "mcp"
            "launch"
            "atlas"
            "${pkgs.python3}/bin/python3"
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

        # 3. Brave Search (Secure, No disk secrets)
        brave-search = {
          command = "atlas";
          args = [
            "mcp"
            "launch"
            "brave-search"
            "${pkgs.nodejs_22}/bin/npx"
            "-y"
            "@modelcontextprotocol/server-brave-search"
          ];
        };

        # 4. Standard Servers
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
}
