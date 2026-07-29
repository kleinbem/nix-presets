{ pkgs, ... }:

{
  # Herdr — terminal-based multiplexer for running/attaching to multiple AI
  # coding agent sessions in real PTYs (persistent, SSH-friendly, no Electron).
  # https://herdr.dev
  home.packages = [
    pkgs.herdr
  ];

  xdg.configFile."herdr/config.toml".source = (pkgs.formats.toml { }).generate "herdr-config" {
    session.resume_agents_on_restore = true;

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
      ];
    };
  };
}
