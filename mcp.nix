{ pkgs, config, ... }:

{
  # Ensure Node.js is available for npx
  home.packages = [ pkgs.nodejs_22 ];

  # Declare the secrets we need
  # sops.secrets.github_pat = { };
  # sops.secrets.brave_api_key = { };

  # Use sops.templates to inject real tokens into the config
  sops.templates."Claude/claude_desktop_config.json" = {
    path = "${config.home.homeDirectory}/.config/Claude/claude_desktop_config.json";
    content = builtins.toJSON {
      mcpServers = {
        # 1. Filesystem (Nixified)
        filesystem = {
          command = "${pkgs.nodejs_22}/bin/npx";
          args = [
            "-y"
            "@modelcontextprotocol/server-filesystem"
            "${config.home.homeDirectory}/Develop"
          ];
        };

        # 2. Workspace Atlas (Custom Nix-Native)
        workspace-atlas = {
          command = "${pkgs.python3}/bin/python3";
          args = [
            "${config.home.homeDirectory}/Develop/github.com/kleinbem/nix/scripts/workspace-mcp.py"
          ];
        };

        # 3. GitHub (Nixified)
        github = {
          command = "${pkgs.nodejs_22}/bin/npx";
          args = [
            "-y"
            "@modelcontextprotocol/server-github"
          ];
          env = {
            # GITHUB_PERSONAL_ACCESS_TOKEN = config.sops.placeholder.github_pat;
          };
        };

        # 4. Brave Search (Nixified)
        brave-search = {
          command = "${pkgs.nodejs_22}/bin/npx";
          args = [
            "-y"
            "@modelcontextprotocol/server-brave-search"
          ];
          env = {
            # BRAVE_API_KEY = config.sops.placeholder.brave_api_key;
          };
        };

        # 5. Puppeteer (Nixified)
        puppeteer = {
          command = "${pkgs.nodejs_22}/bin/npx";
          args = [
            "-y"
            "@modelcontextprotocol/server-puppeteer"
          ];
        };

        # 6. Database (Postgres) — connection string should be updated when DB is provisioned
        postgres = {
          command = "${pkgs.nodejs_22}/bin/npx";
          args = [
            "-y"
            "@modelcontextprotocol/server-postgres"
            "postgresql://user:password@localhost:5432/dbname"
          ];
        };

        # 7. Local Git (Nixified)
        git = {
          command = "${pkgs.nodejs_22}/bin/npx";
          args = [
            "-y"
            "mcp-server-git"
          ];
        };
      };
    };
  };
}
