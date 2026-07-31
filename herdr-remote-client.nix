{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.my.herdr-remote-client;
in
{
  options.my.herdr-remote-client = {
    enable = lib.mkEnableOption "herdr client + SSH shortcut to attach to a remote herdr server";

    serverAlias = lib.mkOption {
      type = lib.types.str;
      default = "nvme";
      description = "SSH Host alias for the herdr server; also the name passed to `herdr --remote`.";
    };

    serverIp = lib.mkOption {
      type = lib.types.str;
      description = "LAN IP or hostname of the machine running the herdr server.";
    };

    serverUser = lib.mkOption {
      type = lib.types.str;
      default = "martin";
      description = "SSH user on the herdr server host.";
    };

    shellAlias = lib.mkOption {
      type = lib.types.str;
      default = "agents";
      description = "Shell alias name for `herdr --remote <serverAlias>`.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.herdr ];

    # ControlMaster/ControlPersist matter whenever the server host requires
    # MFA (e.g. nixos-nvme's publickey+Google-Authenticator sshd tier) —
    # without connection reuse every attach would re-prompt for a code.
    programs.ssh.extraConfig = ''
      Host ${cfg.serverAlias}
        HostName ${cfg.serverIp}
        User ${cfg.serverUser}
        ControlMaster auto
        ControlPath ~/.ssh/control-%C
        ControlPersist 4h
        ServerAliveInterval 60
    '';

    environment.shellAliases.${cfg.shellAlias} = "herdr --remote ${cfg.serverAlias}";
  };
}
