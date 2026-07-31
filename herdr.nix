{ pkgs, config, ... }:

{
  # Herdr — terminal-based multiplexer for running/attaching to multiple AI
  # coding agent sessions in real PTYs (persistent, SSH-friendly, no Electron).
  # https://herdr.dev
  home.packages = [
    pkgs.herdr
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
}
