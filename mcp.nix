{ pkgs, ... }:

{
  # Ensure Node.js is available for npx
  home.packages = [ pkgs.nodejs_22 ];

  xdg.configFile."Claude/claude_desktop_config.json".text = builtins.toJSON {
    mcpServers = {
      # 1. Filesystem (Critical for Coding)
      filesystem = {
        command = "npx";
        args = [
          "-y"
          "@modelcontextprotocol/server-filesystem"
          "/home/martin/Develop"
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
          GITHUB_PERSONAL_ACCESS_TOKEN = "REPLACE_ME_WITH_YOUR_TOKEN";
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
          BRAVE_API_KEY = "REPLACE_ME_WITH_YOUR_KEY";
        };
      };

      # 4. Puppeteer (Browser Automation)
      # Connects to your running 'brave --remote-debugging-port=9222'
      puppeteer = {
        command = "npx";
        args = [
          "-y"
          "@modelcontextprotocol/server-puppeteer"
        ];
        env = {
          # "DOCKER_CONTAINER_LOOPBACK_ADDRESS": "host.docker.internal" # If running inside docker
        };
      };

      # 5. Database (Postgres)
      postgres = {
        command = "npx";
        args = [
          "-y"
          "@modelcontextprotocol/server-postgres"
          "postgresql://user:password@localhost:5432/dbname" # Placeholder connection string
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
}
