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
        PROMPT_COMMAND="history -a; history -n; $PROMPT_COMMAND"

        # --- Bluefin-inspired Welcome Banner ---
        if [[ -z "$TERMINAL_MOTD_SHOWN" && ! -f "$HOME/.config/no-show-user-motd" ]]; then
          export TERMINAL_MOTD_SHOWN=1
          echo -e "\n\e[1;37;44m 🚀 Welcome to your Nix Station \e[0m"
          spec=$(cat /etc/specialisation 2>/dev/null || echo "base")
          if [ "$spec" = "base" ]; then
            echo -e "\e[38;5;244m 󱄅  $(hostname) | NixOS $(nixos-version | cut -d' ' -f1) \e[0m\n"
          else
            echo -e "\e[38;5;244m 󱄅  $(hostname) \e[1;33m($spec)\e[0;38;5;244m | NixOS $(nixos-version | cut -d' ' -f1) \e[0m\n"
          fi

          echo -e " \e[1;34m>_ Command\e[0m             | \e[1;34mDescription\e[0m"
          echo -e " -----------------------|---------------------------------------"
          echo -e " \e[31mos\e[0m                     | Show all available system commands"
          echo -e " \e[31mos rebuild\e[0m             | Apply changes to your configuration"
          echo -e " \e[31mos clean\e[0m               | Clean up old generations & free space"
          echo -e " \e[31mopen <file>\e[0m            | Open any file or URL from terminal"
          echo -e " \e[31mdevenv shell\e[0m          | Enter a project-specific dev environment"
          echo ""
          echo -e " • 󰊤 \e[32mRepo\e[0m   \e[4mhttps://github.com/kleinbem/nix\e[0m"
          echo -e " • 󰋖 \e[32mDocs\e[0m   \e[4mhttps://nixos.org/manual/nixos/stable/\e[0m"
          echo ""
        fi

        # --- System Health Check ---
        if systemctl is-system-running --quiet | grep -q "degraded"; then
          echo -e "\e[1;31m  🚨 SYSTEM DEGRADED: Some services failed to start.\e[0m"
          echo -e "  \e[33mRun 'systemctl --failed' to investigate.\e[0m\n"
        fi
      '';

      shellAliases = {
        ls = "eza --icons";
        ll = "eza -l --icons --git";
        tree = "eza --tree --icons";
        update = "nh os switch";
        cleanup = "nh clean all";
        hm-logs = "journalctl -xeu home-manager-${config.home.username}.service";
        claude = "sudo -v && \\claude";

        # System Control
        os = "just --justfile ~/.justfile";
        open = "xdg-open";
      };
    };

    zsh = {
      enable = true;
      initContent = ''

      '';
    };

    starship = {
      enable = true;
      settings = {
        add_newline = true;
        scan_timeout = 100;
        character = {
          success_symbol = "[➜](bold cyan)";
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
          disabled = true;
        };
        custom = {
          specialisation = {
            description = "Show active NixOS specialisation";
            command = "cat /etc/specialisation";
            when = "test -f /etc/specialisation && test \"$(cat /etc/specialisation)\" != \"base\"";
            format = "in [󱄅 $output]($style) ";
            style = "bold yellow";
          };
          devshell = {
            description = "Show active isolated devshell";
            command = "echo -n $STARSHIP_SHELL_SYMBOL$DEV_SHELL_NAME";
            when = "test -n \"$DEV_SHELL_NAME\"";
            format = "via [$output]($style) ";
            style = "bold blue";
          };
        };
        cmd_duration = {
          min_time = 500;
          format = "took [$duration]($style) ";
        };
      };
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
      settings = {
        "*" = {
          AddKeysToAgent = "yes";
          ControlMaster = "auto";
          ControlPath = "~/.ssh/control-%C";
          ControlPersist = "4h";
          ServerAliveInterval = 60;
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
      TERMINAL = "ptyxis";
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
            # Cleanup the backup to prevent collisions on next activation
            ${pkgs.coreutils}/bin/rm -f "$ssh_config.backup"
          fi
        ''
      );
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
}
