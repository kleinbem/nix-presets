{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.obsidian-web;
  inherit (self.lib) mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };
in
{
  options.my.containers.obsidian-web = {
    enable = lib.mkEnableOption "Obsidian Web UI (Nix-Native/Distroless)";
    ip = lib.mkOption {
      type = lib.types.str;
      default = "10.85.46.128/24";
    };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/images/obsidian-web";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "martin";
    };
  }
  // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "obsidian-web";
    inherit cfg;
    innerConfig =
      { pkgs, ... }:
      let
        # Openbox config that auto-maximizes all windows
        openboxRc = pkgs.writeText "rc.xml" ''
          <?xml version="1.0" encoding="UTF-8"?>
          <openbox_config xmlns="http://openbox.org/3.4/rc">
            <applications>
              <application class="*">
                <maximized>yes</maximized>
                <decor>no</decor>
              </application>
            </applications>
            <theme><font place="ActiveWindow"><size>0</size></font></theme>
          </openbox_config>
        '';
      in
      {
        nixpkgs.config.allowUnfree = true;

        # --- Nix-Native / Distroless Environment ---
        environment.systemPackages = with pkgs; [
          obsidian
          bash
          coreutils
          tigervnc
          novnc
          python3Packages.websockify
          openbox # Minimal window manager for Obsidian to render
          xdotool # Window management
          adwaita-icon-theme # Cursor theme
          xorg.xsetroot # Set root cursor
        ];

        # Create the user inside the container
        users.users.${cfg.user} = {
          isNormalUser = true;
          uid = 1000;
          extraGroups = [ "users" ];
        };

        # --- Systemd Orchestrator for Graphical Web UI ---
        systemd.services.obsidian-web = {
          description = "Obsidian Web UI (TigerVNC + noVNC)";
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            User = cfg.user;
            Group = "users";
            WorkingDirectory = "/home/${cfg.user}";
            ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /home/${cfg.user}/.config/obsidian /home/${cfg.user}/.config/openbox";

            # Start Xvnc directly (avoids vncserver xinit dependency),
            # then openbox + obsidian, then websockify to serve noVNC
            ExecStart = pkgs.writeShellScript "start-obsidian-vnc" ''
              export XDG_RUNTIME_DIR=/run/user/1000
              export DISPLAY=:1
              export XCURSOR_THEME=Adwaita
              export XCURSOR_SIZE=24

              # 1. Start Xvnc directly (no xinit needed)
              ${pkgs.tigervnc}/bin/Xvnc :1 \
                -geometry 1920x1080 -depth 24 \
                -SecurityTypes None \
                -localhost 0 &
              sleep 2

              # 2. Set cursor on root window
              ${pkgs.xorg.xsetroot}/bin/xsetroot -cursor_name left_ptr

              # 3. Start openbox with auto-maximize config
              cp ${openboxRc} /home/${cfg.user}/.config/openbox/rc.xml
              ${pkgs.openbox}/bin/openbox --config-file /home/${cfg.user}/.config/openbox/rc.xml &
              sleep 1

              # 4. Start Obsidian on that display
              ${pkgs.obsidian}/bin/obsidian &
              sleep 3

              # 5. Maximize the Obsidian window (belt-and-suspenders)
              ${pkgs.xdotool}/bin/xdotool search --name "Obsidian" windowactivate --sync windowsize 100% 100% || true

              # 6. Prepare noVNC web root with auto-redirect
              NOVNC_DIR=$(mktemp -d)
              cp -rL ${pkgs.novnc}/share/webapps/novnc/* "$NOVNC_DIR/"
              cat > "$NOVNC_DIR/index.html" <<'EOF'
              <!DOCTYPE html><html><head>
              <meta http-equiv="refresh" content="0;url=vnc.html?autoconnect=true&resize=scale">
              </head></html>
              EOF

              # 7. Serve noVNC via websockify (proxies WebSocket → VNC)
              exec ${pkgs.python3Packages.websockify}/bin/websockify \
                --web "$NOVNC_DIR" \
                8080 localhost:5901
            '';
            Restart = "on-failure";
            RestartSec = 5;
          };
        };

        networking.firewall.allowedTCPPorts = [
          8080
          5901
        ];
      };
    bindMounts = {
      "/home/${cfg.user}/Vault" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    };
  });
}
