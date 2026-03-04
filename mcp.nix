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
        # 1. Filesystem (Critical for Coding)
        filesystem = {
          command = "npx";
          args = [
            "-y"
            "@modelcontextprotocol/server-filesystem"
            "${config.home.homeDirectory}/Develop"
          ];
        };

        # 2. GitHub (Repo Management)
        github = {
          command = "npx";
          args = [
            "-y"
            "@modelcontextprotocol/server-github"
          ];
          env = {
            # GITHUB_PERSONAL_ACCESS_TOKEN = config.sops.placeholder.github_pat;
          };
        };

        # 3. Brave Search (Web Knowledge)
        brave-search = {
          command = "npx";
          args = [
            "-y"
            "@modelcontextprotocol/server-brave-search"
          ];
          env = {
            # BRAVE_API_KEY = config.sops.placeholder.brave_api_key;
          };
        };

        # 4. Puppeteer (Browser Automation)
        puppeteer = {
          command = "npx";
          args = [
            "-y"
            "@modelcontextprotocol/server-puppeteer"
          ];
        };

        # 5. Database (Postgres) — connection string should be updated when DB is provisioned
        postgres = {
          command = "npx";
          args = [
            "-y"
            "@modelcontextprotocol/server-postgres"
            "postgresql://user:password@localhost:5432/dbname"
          ];
        };

        # 6. Local Git
        git = {
          command = "npx";
          args = [
            "-y"
            "mcp-server-git"
          ];
        };
      };
    };
  };
}
