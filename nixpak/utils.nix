{ pkgs, nixpak }:

rec {
  mkNixPak = nixpak.lib.nixpak {
    inherit (pkgs) lib;
    inherit pkgs;
  };

  mkSandboxed =
    {
      package,
      name ? package.pname,
      executableName ? package.meta.mainProgram or package.pname or name,
      configDir ? name,
      binPath ? "bin/${executableName}",
      extraPerms ? { },
      extraPackages ? [ ],
      presets ? [ ],
      exportDesktopFiles ? true,
      extraBinNames ? [ ],
      displayName ? null,
    }:
    let
      # Use provided displayName or fallback to package description/name + (Secure)
      finalDisplayName =
        if displayName != null then displayName else "${package.meta.description or name} (Secure)";

      # If extra packages are requested, create a combined environment
      envPackage =
        if extraPackages == [ ] then
          package
        else
          pkgs.symlinkJoin {
            name = "${name}-env";
            paths = [ package ] ++ extraPackages;
          };

      # --- PERMISSION PRESETS ---
      availablePresets = {
        network = {
          bubblewrap.network = true;
        };
        wayland =
          { sloth, ... }:
          {
            bubblewrap.env = {
              NIXOS_OZONE_WL = "1";
              XDG_SESSION_TYPE = "wayland";
              WAYLAND_DISPLAY = sloth.env "WAYLAND_DISPLAY";
            };
          };
        gpu = {
          bubblewrap.bind = {
            dev = [ "/dev/dri" ];
            ro = [
              "/run/opengl-driver"
              "/sys/class/drm"
            ];
          };
        };
        audio =
          { sloth, ... }:
          {
            bubblewrap.bind.rw = [
              (sloth.concat' sloth.runtimeDir "/pipewire-0")
            ];
          };
        usb = {
          bubblewrap.bind = {
            ro = [
              "/sys/bus/usb"
              "/sys/dev"
              "/run/udev"
            ];
          };
        };
        discovery = {
          bubblewrap.bind.ro = [
            "/run/avahi-daemon/socket"
          ];
        };
      };

      # Select requested presets
      activePresets = map (p: availablePresets.${p}) presets;

      sandbox = mkNixPak {
        config =
          { ... }:
          {
            imports = [
              (
                { sloth, ... }:
                {
                  app.package = envPackage;
                  app.binPath = binPath;
                  flatpak.appId = "com.sandboxed.${name}";

                  # Base binds that everyone needs
                  bubblewrap.bind.ro = [
                    "/etc/fonts"
                    "/etc/ssl/certs"
                    "/etc/profiles/per-user"
                    "/run/dbus"
                    (sloth.concat' sloth.homeDir "/.icons")
                  ];

                  bubblewrap.bind.rw = [
                    (sloth.env "XDG_RUNTIME_DIR")
                    "/tmp"
                    (sloth.concat' sloth.homeDir "/.config/${configDir}")
                  ];
                }
              )
              extraPerms
            ]
            ++ activePresets;
          };
      };

      # Fixed W04: Assignment instead of inherit
      inherit (sandbox.config) script;

    in
    pkgs.runCommand "${name}-sandboxed" { } ''
      mkdir -p $out/bin
      ln -s ${script}/bin/${executableName} $out/bin/${name}

      for extraBin in ${toString extraBinNames}; do
        ln -s ${script}/bin/${executableName} $out/bin/$extraBin
      done

      if ${pkgs.lib.boolToString exportDesktopFiles} && [ -d "${package}/share" ]; then
        mkdir -p $out/share
        if [ -d "${package}/share/icons" ]; then
          ln -s ${package}/share/icons $out/share/icons
        fi
        if [ -d "${package}/share/applications" ]; then
          mkdir -p $out/share/applications
          for f in ${package}/share/applications/*.desktop; do
            # Rename the desktop file to match the sandbox name to avoid collisions
            target="$out/share/applications/${name}.desktop"
            cp -L "$f" "$target"
            chmod u+w "$target"
            sed -i "s|^Exec=.*|Exec=$out/bin/${name} %u|" "$target"
            sed -i "s|^Name=.*|Name=${finalDisplayName}|" "$target"
          done
        fi
      fi
    '';
}
