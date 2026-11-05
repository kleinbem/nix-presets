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

  agentNames = lib.attrNames cfg.agents;
  taskAgent = if cfg.task.agent != null then cfg.task.agent else lib.head (agentNames ++ [ "" ]);

  # main.py reads the team from JSON, so roles and goals need no Python quoting.
  teamJson = pkgs.writeText "agent-team.json" (
    builtins.toJSON {
      agents = lib.mapAttrs (_: a: {
        inherit (a)
          role
          goal
          backstory
          memory
          verbose
          ;
        allow_delegation = a.allowDelegation;
      }) cfg.agents;
      task = {
        inherit (cfg.task) description;
        expected_output = cfg.task.expectedOutput;
        agent = taskAgent;
        human_input = cfg.manager.humanInTheLoop;
      };
      inherit (cfg.manager) process;
      manager_llm = cfg.manager.llm;
    }
  );

  mainPy = pkgs.writeText "main.py" ''
    import json

    from crewai import Agent, Crew, Process, Task

    with open("${teamJson}") as f:
        team = json.load(f)

    agents = {name: Agent(**spec) for name, spec in team["agents"].items()}

    task = Task(
        description=team["task"]["description"],
        expected_output=team["task"]["expected_output"],
        agent=agents[team["task"]["agent"]],
        human_input=team["task"]["human_input"],
    )

    crew_args = {}
    if team["process"] == "hierarchical":
        crew_args["manager_llm"] = team["manager_llm"]

    crew = Crew(
        agents=list(agents.values()),
        tasks=[task],
        process=Process(team["process"]),
        verbose=True,
        **crew_args,
    )

    if __name__ == "__main__":
        print("CrewAI team starting:", ", ".join(agents))
        print(crew.kickoff())
  '';

  venv = "/app/state/venv";
  # crewai's requires-python stops below 3.14. no-link: a declared support
  # range, not a bug; the 3.14 request crewAIInc/crewAI#5109 went stale.
  python = pkgs.python313;

  # A venv left half-built by a failed install never counts as ready: it's
  # built aside (relocatable, so its scripts survive the move) and moved into
  # place only once the install succeeded.
  prepareVenv = pkgs.writeShellScript "agent-team-venv" ''
    set -eu
    if [ ! -x ${venv}/bin/python ]; then
      rm -rf ${venv}.tmp
      ${pkgs.uv}/bin/uv venv --relocatable --python ${python}/bin/python3 ${venv}.tmp
      ${pkgs.uv}/bin/uv pip install --no-cache --python ${venv}.tmp/bin/python crewai langfuse
      rm -rf ${venv}
      mv -T ${venv}.tmp ${venv}
    fi
    cp ${mainPy} /app/workspace/main.py
  '';

  # Used by the unit and by a human over ssh, so it sets up its own env.
  crewRun = pkgs.writeShellScriptBin "crew-run" ''
    set -eu
    set -a
    . /run/secrets/agent-team.env
    set +a
    : "''${OPENAI_API_KEY:?set OPENAI_API_KEY (the LiteLLM key) in secretsFile}"
    export OPENAI_API_BASE=${lib.escapeShellArg cfg.litellmUrl}
    export LANGFUSE_HOST=${lib.escapeShellArg cfg.langfuse.host}
    ${lib.optionalString (cfg.langfuse.publicKey != "") ''
      export LANGFUSE_PUBLIC_KEY=''${LANGFUSE_PUBLIC_KEY:-${lib.escapeShellArg cfg.langfuse.publicKey}}
    ''}
    export OTEL_SDK_DISABLED=${if cfg.langfuse.enable then "false" else "true"}
    export CREWAI_TELEMETRY_OPT_OUT=true
    export PYTHONUNBUFFERED=1
    export PYTHONPATH=/app/workspace
    cd /app/workspace
    exec ${venv}/bin/python /app/workspace/main.py
  '';
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
      description = "Host path to an env file (KEY=VALUE lines) with OPENAI_API_KEY (the LiteLLM key) and, with langfuse, LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY. Required.";
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "SSH public keys allowed to root@ inside the container (human-in-the-loop access). Pass `config.users.users.<name>.openssh.authorizedKeys.keys` from the host.";
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
      description = "Definition of agents in the team. Maps to CrewAI Agent class. At least one is required.";
    };

    task = {
      description = lib.mkOption {
        type = lib.types.str;
        default = "Audit the current NixOS security policies in the workspace and suggest improvements.";
      };
      expectedOutput = lib.mkOption {
        type = lib.types.str;
        default = "A detailed security audit report with actionable Nix code snippets.";
      };
      agent = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Name of the agent (a key of `agents`) the task goes to. null = the first agent by name.";
      };
    };

    manager = {
      humanInTheLoop = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Ask a human to review the task result (CrewAI `human_input`). That
          reads stdin, so the unit then only prepares the environment and the
          crew runs when a human starts `crew-run` over ssh.
        '';
      };
      process = lib.mkOption {
        type = lib.types.enum [
          "sequential"
          "hierarchical"
        ];
        default = "hierarchical";
        description = "How tasks are handed off between agents.";
      };
      llm = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "gpt-4o";
        description = "Model name (on LiteLLM) for the manager. Required when process is hierarchical.";
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
        description = "Langfuse public key. The secret key goes in secretsFile.";
      };
      secretKey = lib.mkOption {
        type = lib.types.str;
        default = "";
        visible = false;
        description = "Removed: an option value lands in the Nix store. Put LANGFUSE_SECRET_KEY in secretsFile.";
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "http://10.85.46.110:3000";
      };
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = cfg.agents != { };
            message = "my.containers.agent-team.agents is empty: define at least one agent.";
          }
          {
            assertion = cfg.agents == { } || cfg.agents ? ${taskAgent};
            message = "my.containers.agent-team.task.agent must be one of: ${lib.concatStringsSep ", " agentNames}.";
          }
          {
            assertion = cfg.manager.process == "hierarchical" -> cfg.manager.llm != null;
            message = ''my.containers.agent-team.manager.process = "hierarchical" needs manager.llm (CrewAI's manager_llm).'';
          }
          {
            assertion = cfg.langfuse.secretKey == "";
            message = "my.containers.agent-team.langfuse.secretKey is removed: an option value lands in the Nix store. Put LANGFUSE_SECRET_KEY in secretsFile.";
          }
          {
            assertion = cfg.secretsFile != null;
            message = "my.containers.agent-team.secretsFile is required: it carries OPENAI_API_KEY (the LiteLLM key).";
          }
        ];
      }
      (mkContainer {
        inherit config;
        name = "agent-team";
        inherit cfg;
        # Bind-mounts to /run/secrets/agent-team.env — see factory.nix's
        # secretsFile doc comment.
        inherit (cfg) secretsFile;
        innerConfig = {
          # Provide necessary packages natively (Distroless)
          environment.systemPackages = [
            python
            pkgs.uv
            pkgs.bash
            pkgs.git # CrewAI often needs git for tools
            crewRun
          ];

          systemd.services.crew-orchestrator = {
            description = "CrewAI Team Orchestrator (Nix-Native)";
            after = [ "network-online.target" ];
            wants = [ "network-online.target" ];
            wantedBy = [ "multi-user.target" ];
            environment.UV_PYTHON_DOWNLOADS = "never";
            serviceConfig =
              if cfg.manager.humanInTheLoop then
                {
                  Type = "oneshot";
                  RemainAfterExit = true;
                  ExecStart = prepareVenv;
                }
              else
                {
                  Type = "simple";
                  ExecStartPre = prepareVenv;
                  ExecStart = "${crewRun}/bin/crew-run";
                  # The first start downloads crewai's whole dependency tree.
                  TimeoutStartSec = "30min";
                  Restart = "on-failure";
                  RestartSec = "10s";
                };
          };

          # Facilitate Human-in-the-Loop via SSH/Exec into the container
          services.openssh.enable = true;
          users.users.root.openssh.authorizedKeys.keys = cfg.authorizedKeys;

          networking.firewall.allowedTCPPorts = [
            8000
            22
          ];
        };

        bindMounts = {
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
      })
    ]
  );
}
