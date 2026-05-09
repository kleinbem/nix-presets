{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.agent-team;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };

in
{
  options.my.containers.agent-team = {
    enable = lib.mkEnableOption "CrewAI Enterprise Agent Team Container";
    ip = lib.mkOption {
      type = lib.types.str;
      default = "10.85.46.126/24";
    };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/images/agent-team";
      description = "Where to store container images and persistent podman state.";
    };
    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    cpuLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    # Team Configuration
    agents = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            role = lib.mkOption { type = lib.types.str; };
            goal = lib.mkOption { type = lib.types.str; };
            backstory = lib.mkOption { type = lib.types.str; };
            allowDelegation = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            memory = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            verbose = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
          };
        }
      );
      default = { };
      description = "Definition of agents in the team. Maps to CrewAI Agent class.";
    };

    manager = {
      humanInTheLoop = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable human-in-the-loop approval for tasks.";
      };
      process = lib.mkOption {
        type = lib.types.enum [
          "sequential"
          "hierarchical"
        ];
        default = "hierarchical";
        description = "How tasks are handed off between agents.";
      };
    };

    litellmUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://10.85.46.115:4000";
      description = "Connection string for the LiteLLM gateway.";
    };

    langfuse = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      publicKey = lib.mkOption {
        type = lib.types.str;
        default = "";
      };
      secretKey = lib.mkOption {
        type = lib.types.str;
        default = "";
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "http://10.85.46.110:3000";
      };
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "agent-team";
    inherit cfg;
    innerConfig = {
      # 1. Provide necessary packages natively (Distroless)
      environment.systemPackages = [
        pkgs.python3
        pkgs.uv
        pkgs.bash
        pkgs.git # CrewAI often needs git for tools
      ];

      # 2. Native Systemd Service (Orchestrator)
      systemd.services.crew-orchestrator = {
        description = "CrewAI Team Orchestrator (Nix-Native)";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];

        environment = {
          OPENAI_API_BASE = cfg.litellmUrl;
          OPENAI_API_KEY = "sk-team-key";
          OTEL_SDK_DISABLED = if cfg.langfuse.enable then "false" else "true";
          LANGFUSE_PUBLIC_KEY = cfg.langfuse.publicKey;
          LANGFUSE_SECRET_KEY = cfg.langfuse.secretKey;
          LANGFUSE_HOST = cfg.langfuse.host;
          CREWAI_TELEMETRY_OPT_OUT = "true";
          # Python specific
          PYTHONUNBUFFERED = "1";
          PYTHONPATH = "/app/workspace";
          UV_PROJECT_ENVIRONMENT = "/app/state/venv";
        };

        serviceConfig = {
          Type = "simple";
          WorkingDirectory = "/app/workspace";
          EnvironmentFile = lib.optional (cfg.secretsFile != null) "/run/secrets/agent-team.env";
          # First-run initialization and then start orchestrator
          ExecStart =
            let
              # Helper to escape Python strings
              pyStr = s: "'''${s}'''";

              # Generate the Python agent definitions
              agentsPy = lib.concatStringsSep "\n" (
                lib.mapAttrsToList (name: agent: ''
                  ${name} = Agent(
                      role=${pyStr agent.role},
                      goal=${pyStr agent.goal},
                      backstory=${pyStr agent.backstory},
                      allow_delegation=${if agent.allowDelegation then "True" else "False"},
                      memory=${if agent.memory then "True" else "False"},
                      verbose=${if agent.verbose then "True" else "False"}
                  )
                '') cfg.agents
              );

              mainPy = pkgs.writeText "main.py" ''
                import os
                from crewai import Agent, Task, Crew, Process

                # Initialize Agents from Nix Configuration
                ${agentsPy}

                # Define a generic task for the team
                # In a real scenario, this would be driven by an external API or file
                task1 = Task(
                    description="Audit the current NixOS security policies in the workspace and suggest improvements.",
                    expected_output="A detailed security audit report with actionable Nix code snippets.",
                    agent=auditor if 'auditor' in locals() else developer
                )

                # Instantiate the Crew
                crew = Crew(
                    agents=[${lib.concatStringsSep ", " (lib.attrNames cfg.agents)}],
                    tasks=[task1],
                    process=Process.${cfg.manager.process},
                    verbose=True
                )

                if __name__ == "__main__":
                    print("🚀 CrewAI Team starting task execution...")
                    result = crew.kickoff()
                    print("\n\n✨ FINAL RESULT:\n")
                    print(result)
              '';
            in
            pkgs.writeShellScript "start-crew" ''
              if [ ! -d "/app/state/venv" ]; then
                echo "⚙️ Initializing 'Distroless' Python environment with uv..."
                ${pkgs.uv}/bin/uv venv --python ${pkgs.python3}/bin/python3 /app/state/venv
                ${pkgs.uv}/bin/uv pip install --no-cache crewai langfuse
              fi

              source /app/state/venv/bin/activate

              # Copy the Nix-generated main.py to the workspace if it doesn't exist or has changed
              cp ${mainPy} /app/workspace/main.py

              echo "🚀 CrewAI Team Ready. Roles Loaded: ${lib.concatStringsSep ", " (lib.attrNames cfg.agents)}"
              python3 /app/workspace/main.py
            '';
          Restart = "on-failure";
          RestartSec = "10s";
        };
      };

      # Facilitate Human-in-the-Loop via SSH/Exec into the container
      services.openssh.enable = true;
      users.users.root.openssh.authorizedKeys.keys =
        config.users.users.martin.openssh.authorizedKeys.keys;

      networking.firewall.allowedTCPPorts = [
        8000
        22
      ];
    };

    bindMounts =
      (lib.optionalAttrs (cfg.secretsFile != null) {
        "/run/secrets/agent-team.env" = {
          hostPath = cfg.secretsFile;
          isReadOnly = true;
        };
      })
      // {
        # Redirect internal paths to host persistence
        "/app/workspace" = {
          hostPath = "${cfg.hostDataDir}/workspace";
          isReadOnly = false;
        };
        "/app/state" = {
          hostPath = "${cfg.hostDataDir}/state";
          isReadOnly = false;
        };
      };
  });
}
