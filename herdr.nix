{
  pkgs,
  config,
  lib,
  inputs,
  ...
}:

{
  # Herdr — terminal-based multiplexer for running/attaching to multiple AI
  # coding agent sessions in real PTYs (persistent, SSH-friendly, no Electron).
  # https://herdr.dev
  home.packages = [
    pkgs.herdr

    # Hermes Agent (Nous Research) — terminal-native coding agent, run
    # interactively in a Herdr pane alongside claude/opencode. It's a
    # first-class Herdr integration; the state hook is installed by the
    # activation block below. This is the CLI, NOT the headless Discord
    # gateway — that's the separate mac-mini container (my.containers.hermes),
    # which uses the `messaging` build. `minimal` here would trim the closure
    # if that ever matters.
    inputs.hermes.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];

  xdg.configFile."herdr/config.toml".source = (pkgs.formats.toml { }).generate "herdr-config" {
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

  # Herdr's per-agent state hooks (e.g. ~/.claude/hooks/herdr-agent-state.sh)
  # are extracted from the herdr binary by `integration install` and carry a
  # version stamp that must match the binary — a plain package bump silently
  # leaves them stale ("outdated (v7 < v8)"). Re-running the install on every
  # activation is idempotent (overwrites the hook, upserts the agent's
  # settings entry) and, because the string embeds ${pkgs.herdr}, only
  # actually re-runs when the herdr version changes.
  #
  # Each `install` writes into that agent's own config dir. claude/opencode/
  # gemini already have theirs, but Hermes' ~/.hermes is created lazily by
  # `hermes setup` on first interactive run — so on a fresh machine that
  # line would error and abort activation. `|| true` keeps the switch green;
  # the hook installs cleanly on the next switch once ~/.hermes exists (or
  # run `herdr integration install hermes` by hand right after setup).
  home.activation.herdrIntegrations = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.herdr}/bin/herdr integration install claude
    run ${pkgs.herdr}/bin/herdr integration install opencode
    run ${pkgs.herdr}/bin/herdr integration install antigravity-cli
    run ${pkgs.herdr}/bin/herdr integration install hermes || true
  '';
}
