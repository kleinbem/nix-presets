{
  pkgs,
  config,
  lib,
  inputs,
  ...
}:

let
  cfg = config.modules.herdr;

  # Markdown picker for agent output (plans, reports, CLAUDE.md): newest files
  # first, rendered preview beside the list, Enter reads one in glow's pager
  # and returns to the list. --no-require-git keeps .gitignore honoured in jj
  # workspaces, which have no .git.
  mdview = pkgs.writeShellApplication {
    name = "herdr-mdview";
    runtimeInputs = [
      pkgs.fd
      pkgs.fzf
      pkgs.glow
    ];
    text = ''
      # fzf expands $FZF_PREVIEW_COLUMNS, not this shell.
      # shellcheck disable=SC2016
      fd --type f --extension md --no-require-git --exec-batch ls -t -- \
        | fzf --prompt 'md> ' \
          --preview 'glow --style dark --width "$FZF_PREVIEW_COLUMNS" {}' \
          --preview-window 'right,65%' \
          --bind 'enter:execute(glow --pager {})'
    '';
  };

  ntfyEnabled = cfg.ntfy.url != null && cfg.ntfy.topicFile != null;

  # New jj workspace for an agent: pick a fleet repo, name it (empty = auto),
  # then open it as its own herdr workspace. jj-ws-new is the same primitive
  # `just jj::ws-new` ends in.
  wsNew = pkgs.writeShellApplication {
    name = "herdr-jj-ws-new";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.fzf
      pkgs.herdr
      pkgs.jujutsu
    ];
    text = ''
      root=${lib.escapeShellArg cfg.fleetRoot}
      repo=$(
        cd "$root"
        for d in */.jj; do printf '%s\n' "''${d%/.jj}"; done \
          | fzf --prompt 'repo> ' --header 'new jj workspace for an agent'
      ) || exit 0
      read -rp "workspace name (empty = auto): " name
      name=''${name:-ws-$(date +%H%M%S)-$RANDOM}
      if ! (cd "$root/$repo" && "$root/jj-toolbox/bin/jj-ws-new" "$name"); then
        read -rp "jj-ws-new failed, press Enter to close" _
        exit 1
      fi
      herdr workspace create --cwd "$root/$repo.ws/$name" --label "$repo/$name" --focus >/dev/null
    '';
  };

  # Phone push when an agent needs you or finishes. herdr's own toasts only
  # reach the desktop the server runs on, not the remote clients.
  agentNotify = pkgs.writeShellApplication {
    name = "herdr-agent-notify";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.herdr
      pkgs.jq
    ];
    text = ''
      topic=$(cat ${lib.escapeShellArg (toString cfg.ntfy.topicFile)} 2>/dev/null) || exit 0
      [ -n "$topic" ] || exit 0

      ev=''${HERDR_PLUGIN_EVENT_JSON:-}
      status=$(jq -r '.data.agent_status // empty' <<<"$ev")
      pane=$(jq -r '.data.pane_id // empty' <<<"$ev")
      agent=$(jq -r '.data.agent // "agent"' <<<"$ev")
      [ -n "$pane" ] || exit 0

      # Remember the last status per pane: "idle" only means finished when
      # the agent was working before (not on startup or repeat reports).
      state_dir=''${HERDR_PLUGIN_STATE_DIR:-''${XDG_STATE_HOME:-$HOME/.local/state}/herdr-agent-notify}
      mkdir -p "$state_dir"
      state_file="$state_dir/''${pane//[^A-Za-z0-9_-]/_}"
      prev=$(cat "$state_file" 2>/dev/null || true)
      printf '%s\n' "$status" >"$state_file"

      pane_json=$(herdr pane get "$pane" 2>/dev/null || echo '{}')
      case "$status" in
        blocked)
          [ "$prev" != blocked ] || exit 0
          prio=high tags=warning what="needs you"
          ;;
        idle)
          [ "$prev" = working ] || exit 0
          # The pane you're looking at doesn't need a ping for every turn.
          [ "$(jq -r '.result.pane.focused // false' <<<"$pane_json")" != true ] || exit 0
          prio=default tags=white_check_mark what="finished"
          ;;
        *) exit 0 ;;
      esac

      ws=$(jq -r '.result.pane.workspace_id // empty' <<<"$pane_json")
      label=$(herdr workspace get "$ws" 2>/dev/null | jq -r '.result.workspace.label // empty' || true)
      body=$(jq -r '.result.pane.terminal_title_stripped // empty' <<<"$pane_json")

      curl -fsS --max-time 15 \
        -H "Title: $agent $what''${label:+ · $label}" \
        -H "Priority: $prio" -H "Tags: $tags" \
        -d "''${body:-$pane}" \
        ${lib.escapeShellArg cfg.ntfy.url}/"$topic" >/dev/null || true
    '';
  };

  pluginDir = pkgs.writeTextDir "herdr-plugin.toml" (
    builtins.readFile (
      (pkgs.formats.toml { }).generate "herdr-plugin.toml" {
        id = "kleinbem.fleet";
        name = "kleinbem fleet";
        version = "0.1.0";
        min_herdr_version = "0.9.0";
        platforms = [ "linux" ];
        events = [
          {
            on = "pane.agent_status_changed";
            command = [ (lib.getExe agentNotify) ];
          }
        ];
      }
    )
  );

  herdrConfigFile = (pkgs.formats.toml { }).generate "herdr-config" {
    session.resume_agents_on_restore = true;

    # tokyo-night matches the zellij theme in terminal.nix, so every
    # multiplexer in this setup shares one palette.
    theme.name = "tokyo-night";

    ui = {
      # Across ~15 sibling repos, the useful sidebar ordering is "which agent
      # needs me right now", not alphabetical-by-repo.
      agent_panel_sort = "priority";
      show_agent_labels_on_pane_borders = true;

      toast = {
        # Native desktop notification the moment a background agent finishes
        # or needs input — the point of running several agents unattended
        # across the fleet instead of watching one terminal.
        delivery = "system";
      };
    };

    keys = {
      prefix = "ctrl+b";
      command = [
        {
          key = "prefix+g";
          type = "popup";
          command = "lazygit";
          description = "run lazygit";
          width = "80%";
          height = "80%";
        }
        {
          key = "prefix+j";
          type = "popup";
          command = "jjui";
          description = "run jjui";
          width = "80%";
          height = "80%";
        }
        {
          key = "prefix+l";
          type = "popup";
          command = "jj log";
          description = "jj log";
          width = "80%";
          height = "80%";
        }
        {
          key = "prefix+t";
          type = "popup";
          command = "btop";
          description = "system monitor";
          width = "80%";
          height = "80%";
        }
        {
          key = "prefix+y";
          type = "popup";
          command = "yazi";
          description = "file browser";
          width = "80%";
          height = "80%";
        }
        {
          key = "prefix+m";
          type = "popup";
          command = lib.getExe mdview;
          description = "markdown viewer";
          width = "90%";
          height = "90%";
        }
        {
          key = "prefix+a";
          type = "popup";
          command = lib.getExe wsNew;
          description = "new jj workspace for an agent";
          width = "60%";
          height = "60%";
        }
        {
          key = "prefix+f";
          type = "popup";
          # Absolute -f/-d so this works from a popup opened inside any
          # sibling repo, not just from the workspace root.
          command = "just -f ${cfg.fleetRoot}/justfile -d ${cfg.fleetRoot}";
          description = "kleinbem fleet hub";
          width = "80%";
          height = "80%";
        }
      ];
    };
  };
in
{
  options.modules.herdr = {
    enable = lib.mkEnableOption "Herdr terminal workspace manager for AI coding agents";

    fleetRoot = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/Develop/github.com/kleinbem";
      description = "Workspace root holding the fleet repos (fleet hub and jj workspace popups).";
    };

    ntfy = {
      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "https://ntfy.example.org";
        description = "ntfy server for agent blocked/finished pushes. Set on the host that runs the herdr server.";
      };
      topicFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "File holding the ntfy topic (a secret), readable by the herdr user.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home = {
      # Herdr — terminal-based multiplexer for running/attaching to multiple AI
      # coding agent sessions in real PTYs (persistent, SSH-friendly, no Electron).
      # https://herdr.dev
      packages = [
        pkgs.herdr

        # Google Antigravity CLI (`agy`) — built by nix-packages, reachable here
        # via its overlay (modules/nixos/base.nix, useGlobalPkgs = true). Without
        # this, herdr's `antigravity-cli` integration has an installed hook
        # (herdr integration install antigravity-cli, below) but nothing to
        # actually launch a pane with.
        pkgs.google-antigravity-cli

        # Hermes Agent (Nous Research) — terminal-native coding agent, run
        # interactively in a Herdr pane alongside claude/opencode. It's a
        # first-class Herdr integration; the state hook is installed by the
        # activation block below. This is the CLI, NOT the headless Discord
        # gateway — that's the separate mac-mini container (my.containers.hermes),
        # which uses the `messaging` build. `minimal` here would trim the closure
        # if that ever matters.
        inputs.hermes.packages.${pkgs.stdenv.hostPlatform.system}.default

        # Native Zsh completion for Herdr CLI
        (pkgs.runCommand "herdr-zsh-completion" { } ''
          mkdir -p $out/share/zsh/site-functions
          ${pkgs.herdr}/bin/herdr completion zsh > $out/share/zsh/site-functions/_herdr
        '')
      ];

      shellAliases = {
        # Unified alias matching the remote fleet client shortcut
        agents = "herdr";
      };

      activation = {
        # herdr has exactly one config file (`herdr --help` → "Config:
        # ~/.config/herdr/config.toml") and persists runtime UI state into it too
        # (agent_panel_sort changes, the onboarding-seen flag, ...) — there's no
        # separate state file. A plain xdg.configFile symlink into the Nix store
        # made every one of those writes fail with "Read-only file system (os
        # error 30)" (see herdr-server.log: context="onboarding setting" /
        # context="agent panel sort"). Seed it as a real, writable copy instead,
        # and merge declarative keys (theme, keys, ui, session) without wiping
        # runtime UI state.
        herdrConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          configPath="${config.xdg.configHome}/herdr/config.toml"
          if [ ! -e "$configPath" ]; then
            run install -Dm644 ${herdrConfigFile} "$configPath"
          elif [ -L "$configPath" ]; then
            rm -f "$configPath"
            run install -Dm644 ${herdrConfigFile} "$configPath"
          else
            tmpConfig=$(mktemp --suffix=.toml)
            ${pkgs.yq-go}/bin/yq eval-all -p toml -o toml 'select(fileIndex == 0) * select(fileIndex == 1)' "$configPath" "${herdrConfigFile}" > "$tmpConfig"
            run install -m644 "$tmpConfig" "$configPath"
            rm -f "$tmpConfig"
          fi
        '';

        # Re-linking the same plugin id replaces the registered path, so each
        # generation points herdr at its own store copy. Without ntfy the
        # plugin has nothing to do; unlink it.
        herdrPlugin = lib.hm.dag.entryAfter [ "herdrConfig" ] (
          if ntfyEnabled then
            ''
              run ${pkgs.coreutils}/bin/timeout 15 ${pkgs.herdr}/bin/herdr plugin link ${pluginDir} >/dev/null || true
            ''
          else
            ''
              run ${pkgs.coreutils}/bin/timeout 15 ${pkgs.herdr}/bin/herdr plugin unlink kleinbem.fleet >/dev/null 2>&1 || true
            ''
        );

        # Herdr's per-agent state hooks (e.g. ~/.claude/hooks/herdr-agent-state.sh)
        # are extracted from the herdr binary by `integration install` and carry a
        # version stamp that must match the binary — a plain package bump silently
        # leaves them stale ("outdated (v7 < v8)"). Re-running the install on every
        # activation is idempotent (overwrites the hook, upserts the agent's
        # settings entry) and, because the string embeds ${pkgs.herdr}, only
        # actually re-runs when the herdr version changes.
        #
        # Also exports the bundled herdr agent skill for Claude Code and Antigravity.
        herdrIntegrations = lib.hm.dag.entryAfter [ "herdrConfig" ] ''
          run ${pkgs.herdr}/bin/herdr integration install claude
          run ${pkgs.herdr}/bin/herdr integration install opencode
          run ${pkgs.herdr}/bin/herdr integration install antigravity-cli
          run ${pkgs.herdr}/bin/herdr integration install hermes || true
          run ${pkgs.herdr}/bin/herdr integration install cursor || true

          # Synchronize Herdr agent skills for autonomous AI tools
          run mkdir -p "${config.home.homeDirectory}/.gemini/config/skills/herdr" "${config.home.homeDirectory}/.claude/skills/herdr"
          ${pkgs.herdr}/bin/herdr --skill > "${config.home.homeDirectory}/.gemini/config/skills/herdr/SKILL.md"
          ${pkgs.herdr}/bin/herdr --skill > "${config.home.homeDirectory}/.claude/skills/herdr/SKILL.md"
        '';
      };
    };

    xdg.desktopEntries.herdr = {
      name = "Herdr";
      genericName = "AI Coding Agent Multiplexer";
      comment = "Terminal workspace manager for AI coding agents";
      exec = "ghostty -e herdr";
      icon = "utilities-terminal";
      terminal = false;
      categories = [
        "Development"
        "Utility"
      ];
    };
  };
}
