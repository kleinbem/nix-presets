{
  pkgs,
  config,
  lib,
  inputs,
  ...
}:

let
  cfg = config.modules.herdr;
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
          key = "prefix+f";
          type = "popup";
          # Absolute -f/-d so this works from a popup opened inside any
          # sibling repo, not just from the workspace root.
          command = "just -f ${config.home.homeDirectory}/Develop/github.com/kleinbem/justfile -d ${config.home.homeDirectory}/Develop/github.com/kleinbem";
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
