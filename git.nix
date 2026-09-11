{
  pkgs,
  config,
  my,
  ...
}:

let
  # jj-toolbox (~/Develop/github.com/kleinbem/jj-toolbox) — generic jj
  # enhancements, not tied to this fleet's repos, cwd-scoped like any
  # built-in jj command. `jj util exec` is jj's own documented way to chain
  # multiple commands behind one alias.
  jjToolboxBin = "${config.home.homeDirectory}/Develop/github.com/kleinbem/jj-toolbox/bin";
  jjToolboxTool = name: [ "util" "exec" "--" "${jjToolboxBin}/jj-${name}" ];
in

{
  home.packages = [
    pkgs.git-credential-oauth
  ];

  programs = {
    delta = {
      enable = true;
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

    jujutsu = {
      enable = true;
      settings = {
        user = {
          inherit (my.git) name email;
        };
        ui.diff.tool = [
          "difft"
          "--color=always"
          "$left"
          "$right"
        ];
        signing = {
          # jj 0.42+ renamed `sign-all = true` to `behavior = "own"`. With this
          # set, `jj describe` signs every commit at creation time — the
          # `sign-unsigned` recipe becomes a backstop only, not a routine step.
          # Works touchlessly with the V2 SSH-FIDO key (no-touch-required).
          behavior = "own";
          backend = "ssh";
        };
        aliases = {
          save = jjToolboxTool "save";
          sweep-merged = jjToolboxTool "sweep-merged";
          check-signatures = jjToolboxTool "check-signatures";
          push = jjToolboxTool "push";
          pull = jjToolboxTool "pull";
          sign-unsigned = jjToolboxTool "sign-unsigned";
          ws-new = jjToolboxTool "ws-new";
          ws-list = jjToolboxTool "ws-list";
          ws-gc = jjToolboxTool "ws-gc";
        };
      };
    };

    git = {
      enable = true;
      lfs.enable = true;

      # Global Default Settings (Fallback)
      settings = {
        user = {
          inherit (my.git) name email;
        };
        alias = {
          st = "status";
          co = "checkout";
          sw = "switch";
          br = "branch";
          gl = "log --graph --pretty=format:'%C(yellow)%h%C(reset) %C(bold magenta)%G?%C(reset) -%C(red)%d%C(reset) %s %C(dim green)(%cr) %C(bold blue)<%an>%C(reset)'";
        };
        commit.gpgsign = true;
        gpg = {
          format = "ssh";
          ssh = {
            # Wrap any IDE-provided SSH_ASKPASS (VS Code / Antigravity IDE) to
            # strip trailing newlines — those break FIDO2 PIN inputs.
            #
            # NOTE: do NOT unset SSH_AUTH_SOCK here. user.signingKey is set as
            # `key::<inline blob>` in users/martin/home.nix, which causes git
            # to invoke ssh-keygen with `-U` ("key resides in ssh-agent"). If
            # the agent socket is stripped, ssh-keygen errors with "Couldn't
            # get agent socket" and the commit fails. Let the agent through.
            program = "${pkgs.writeShellScript "git-ssh-sign" ''
              if [ -n "$SSH_ASKPASS" ] && [ "$SSH_ASKPASS" != "ide-askpass-wrapper" ]; then
                export REAL_ASKPASS="$SSH_ASKPASS"
                export SSH_ASKPASS="${pkgs.writeShellScript "ide-askpass-wrapper" ''
                  "$REAL_ASKPASS" "$@" | tr -d '\n'
                ''}"
              fi
              ssh-keygen -Y sign "$@"
            ''}";
            allowedSignersFile = "${config.home.homeDirectory}/.ssh/allowed_signers";
          };
        };

        # Painless HTTPS Logins (Browser Pop-up instead of keys/passwords)
        # Replaces raw SSH pushing for standard repositories
        credential.helper = [
          "oauth"
          "cache --timeout 3600"
        ];

        # Route github.com SSH remotes over HTTPS so raw git network ops
        # (fetch, ls-remote, push from IDEs/agents) use the oauth helper
        # instead of demanding a FIDO2 touch on id_ed25519_sk. The just
        # recipes already push via HTTPS+gh; this makes ad-hoc git match.
        url."https://github.com/".insteadOf = "git@github.com:";
      };

      # ==========================================
      # Conditional Profiles (Directory-based Handoff)
      # ==========================================
      includes = [
        {
          condition = "gitdir:~/Develop/github.com/";
          contents = {
            user.email = my.git.email; # Modify if you use a distinct github.com email
          };
        }
        {
          condition = "gitdir:~/Develop/gitlab.com/";
          contents = {
            # Automatically swap identity for GitLab projects
            user.email = my.git.email; # Example: "martin.gitlab@domain.com";
          };
        }
        {
          condition = "gitdir:~/Develop/bitbucket.org/";
          contents = {
            # Automatically swap identity for Bitbucket projects
            user.email = my.git.email;
          };
        }
        {
          condition = "gitdir:~/Develop/amazon.com/";
          contents = {
            # Identity for Amazon / AWS CodeCommit / CodeCatalyst
            user.email = my.git.email;
          };
        }
        {
          condition = "gitdir:~/Develop/google.com/";
          contents = {
            # Identity for Google / GCP Cloud Source Repositories
            user.email = my.git.email;
          };
        }
        {
          condition = "gitdir:~/Develop/microsoft.com/";
          contents = {
            # Identity for Microsoft / Azure DevOps / GitHub Enterprise
            user.email = my.git.email;
          };
        }
      ];
    };
  };
}
