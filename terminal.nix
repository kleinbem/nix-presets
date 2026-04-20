{
  pkgs,
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
        yubi-mount = "ssh-add -s ${pkgs.opensc}/lib/opensc-pkcs11.so";
        hm-logs = "journalctl -xeu home-manager-${config.home.username}.service";

        # System Control
        os = "just --justfile ~/.justfile";
      };
    };

    starship = {
      enable = true;
      settings = {
        add_newline = true;
        scan_timeout = 100;
        character = {
          success_symbol = "[➜](bold green)";
          error_symbol = "[✗](bold red)";
        };
        directory = {
          truncation_length = 0;
          truncate_to_repo = false;
        };
        git_status = {
          disabled = false;
          ignore_submodules = true;
        };
        direnv = {
          disabled = false;
          symbol = "󱄅 ";
          style = "bold orange";
        };
        nix_shell = {
          symbol = " ";
          format = "via [$symbol$name]($style) ";
          style = "bold blue";
        };
        cmd_duration = {
          min_time = 500;
          format = "took [$duration]($style) ";
        };
      };
    };

    keychain = {
      enable = false; # Disabled to prevent conflict with system-wide ssh-agent
      enableBashIntegration = true;
      keys = [
        "id_ed25519_sk"
        "id_ed25519_sk_backup"
        "id_ed25519_sk_no_touch"
        "id_ecdsa_sk_auth"
        "id_ecdsa_sk_auth_backup"
      ];
    };

    direnv = {
      enable = true;
      nix-direnv.enable = true;
      config.global = {
        hide_env_diff = true;
        warn_timeout = "30s";
      };
      stdlib = ''
        use_devenv() {
          # Automatically detect the workspace root (Git toplevel)
          local root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
          
          if has devenv && [[ -f "$root/devenv.nix" || -f "$root/devenv.yaml" ]]; then
            # Watch files relative to root
            watch_file "$root/devenv.nix"
            watch_file "$root/devenv.yaml"
            [[ -f "$root/devenv.lock" ]] && watch_file "$root/devenv.lock"
            
            # Load the environment by switching to root (version-agnostic)
            pushd "$root" > /dev/null
            eval "$(devenv print-dev-env)"
            popd > /dev/null
          else
            # Fallback to standard flake loading
            use flake "$root"
          fi
        }
      '';
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

    zellij = {
      enable = true;
      enableBashIntegration = false;
      settings = {
        theme = "tokyo-night";
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
          identityFile = "${config.home.homeDirectory}/.ssh/id_ecdsa_sk_auth";
        };
      };
    };
  };

  home = {
    file = {
      ".justfile" = {
        source = ./files/justfile;
        force = true;
      };
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
      devenv # Added for advanced direnv integration
    ];

  };

  # Rclone setup
  systemd.user.services.setup-rclone-config = {
    Unit = {
      Description = "Setup Rclone Config from Secrets";
      After = [ "sops-nix.service" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = toString (
        pkgs.writeShellScript "setup-rclone-config" ''
          config_dir="$HOME/.config/rclone"
          ${pkgs.coreutils}/bin/mkdir -p "$config_dir"
          ${pkgs.coreutils}/bin/rm -f "$config_dir/rclone.conf"
          ${pkgs.coreutils}/bin/cp -f /run/secrets/rclone_config "$config_dir/rclone.conf"
          ${pkgs.coreutils}/bin/chmod 600 "$config_dir/rclone.conf"
        ''
      );
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  # SSH Config Permission Fix (The NixOS Best Practice)
  # OpenSSH is strict about permissions. Home Manager symlinks to the store are "too open".
  # This service materializes the config as a real file with 600 permissions.
  systemd.user.services.fix-ssh-permissions = {
    Unit = {
      Description = "Fix SSH Config Permissions";
      After = [ "home-manager-generation.service" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = toString (
        pkgs.writeShellScript "fix-ssh-permissions" ''
          ssh_config="$HOME/.ssh/config"
          if [ -L "$ssh_config" ]; then
            ${pkgs.coreutils}/bin/cp --remove-destination "$ssh_config" "$ssh_config.real"
            ${pkgs.coreutils}/bin/mv "$ssh_config.real" "$ssh_config"
            ${pkgs.coreutils}/bin/chmod 600 "$ssh_config"
          fi
        ''
      );
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
