{
  pkgs,
  lib,
  config,
  ...
}:

{
  programs = {
    bash = {
      enable = true;
      initExtra = ''
        # History Sync
        export HISTCONTROL=ignoreboth:erasedups
        export HISTSIZE=100000
        export HISTFILESIZE=100000
        shopt -s histappend
        PROMPT_COMMAND="history -a; history -c; history -r; $PROMPT_COMMAND"
      '';

      shellAliases = {
        ls = "eza --icons";
        ll = "eza -l --icons --git";
        tree = "eza --tree --icons";
        update = "nh os switch";
        cleanup = "nh clean all";
        hm-logs = "journalctl -xeu home-manager-martin.service";

        # System Control
        os = "just --justfile ~/.justfile";
      };
    };

    starship = {
      enable = true;
    };

    keychain = {
      enable = true;
      enableBashIntegration = true;
      keys = [
        "id_ed25519_sk"
        "id_ed25519_sk_backup"
        "id_ed25519_sk_no_touch"
        "id_ecdsa_sk_auth"
        "id_ecdsa_sk_auth_backup"
      ];
    };

    git = {
      enable = true;
      lfs.enable = true;

      settings = {
        user = {
          name = "kleinbem";
          email = "martin.kleinberger@gmail.com";
          signingKey = "/home/martin/.ssh/id_ed25519_sk.pub";
        };

        commit.gpgsign = true;

        # SSH Signing Configuration
        gpg.format = "ssh";
        # This file tells Git which public keys belong to which email addresses.
        # Without this, your local 'git log' will show "Unknown Signature" for your own commits.
        "gpg.ssh".allowedSignersFile = "/home/martin/.ssh/allowed_signers";

        alias = {
          st = "status";
          co = "checkout";
          sw = "switch";
          br = "branch";

          # 'gl' - Graph Log with Signature Verification
          # %h: Hash | %G?: Signature Status (G=Good, B=Bad, U=Unknown)
          # %d: Refs (branches/tags) | %s: Subject | %cr: Date | %an: Author
          gl = "log --graph --pretty=format:'%C(yellow)%h%C(reset) %C(bold magenta)%G?%C(reset) -%C(red)%d%C(reset) %s %C(dim green)(%cr) %C(bold blue)<%an>%C(reset)'";
        };
      };
    };

    direnv = {
      enable = true;
      nix-direnv.enable = true;
      config.global.hide_env_diff = true;
    };

    fzf = {
      enable = true;
      enableBashIntegration = true;
    };

    bat.enable = true;

    zoxide = {
      enable = true;
      enableBashIntegration = true;
    };

    delta = {
      enable = true;
    };

    zellij = {
      enable = true;
      enableBashIntegration = false;
      settings = {
        theme = "tokyo-night";
      };
    };

    lazygit = {
      enable = true;
      settings = {
        gui.theme = {
          lightTheme = false;
          activeBorderColor = [
            "green"
            "bold"
          ];
          inactiveBorderColor = [ "white" ];
          selectedLineBgColor = [ "reverse" ];
        };
      };
    };

    ssh = {
      enable = true;
      enableDefaultConfig = false;
      matchBlocks = {
        "*" = {
          addKeysToAgent = "yes";
          controlMaster = "auto";
          controlPath = "~/.ssh/control-%C";
          controlPersist = "4h";
          serverAliveInterval = 60;
        };
        "github.com" = {
          user = "git";
          identityFile = "/home/martin/.ssh/id_ecdsa_sk_auth";
        };
      };
    };
  };

  xdg.configFile."starship.toml".source = ./files/starship.toml;

  home = {
    file = {
      ".justfile".source = ./files/justfile;
    };

    sessionVariables = {
      TERMINAL = "cosmic-terminal";
    };

    packages = with pkgs; [
      fastfetch
      yazi
      rclone
      lxqt.lxqt-openssh-askpass
      btop # Essential for monitoring n8n/Ollama resources
      usbutils # lsusb
      pciutils # lspci
    ];

    activation = {
      fixSshConfigPermissions = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        if [ -L "$HOME/.ssh/config" ]; then
          $DRY_RUN_CMD rm -f $HOME/.ssh/config
          $DRY_RUN_CMD cp -L ${config.home.file.".ssh/config".source} $HOME/.ssh/config
          $DRY_RUN_CMD chmod 600 $HOME/.ssh/config
        fi
        # Ensure correct ownership/permissions if it's already a file (idempotency)
        if [ -f "$HOME/.ssh/config" ]; then
            $DRY_RUN_CMD chmod 600 $HOME/.ssh/config
        fi
      '';
    };
  };

  # Rclone setup (Unchanged)
  systemd.user.services.setup-rclone-config = {
    Unit = {
      Description = "Setup Rclone Config from Secrets";
      After = [ "sops-nix.service" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.coreutils}/bin/mkdir -p %h/.config/rclone && ${pkgs.coreutils}/bin/rm -f %h/.config/rclone/rclone.conf && ${pkgs.coreutils}/bin/cp -f /run/secrets/rclone_config %h/.config/rclone/rclone.conf && ${pkgs.coreutils}/bin/chmod 600 %h/.config/rclone/rclone.conf'";
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
