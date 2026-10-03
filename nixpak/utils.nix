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
      resourceLimits ? null,
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
        # Native Wayland only: just the compositor socket, no X11
        # (/tmp is a private tmpfs, so /tmp/.X11-unix isn't reachable).
        wayland =
          { sloth, ... }:
          {
            bubblewrap.bind.rw = [
              (sloth.concat [
                sloth.runtimeDir
                "/"
                (sloth.env "WAYLAND_DISPLAY")
              ])
            ];
            bubblewrap.env = {
              NIXOS_OZONE_WL = "1";
              XDG_SESSION_TYPE = "wayland";
              WAYLAND_DISPLAY = sloth.env "WAYLAND_DISPLAY";
            };
          };
        dbus =
          { sloth, ... }:
          {
            bubblewrap.env = {
              DBUS_SESSION_BUS_ADDRESS = sloth.env "DBUS_SESSION_BUS_ADDRESS";
            };
          };
        # nixpak's own module (provider "nixos"): /dev/dri plus the
        # /sys/dev/char + /sys/devices/pci0000:00 entries libdrm needs to
        # enumerate devices — /sys/class/drm alone is just dangling symlinks.
        gpu = {
          gpu.enable = true;
          bubblewrap.bind.ro = [ "/sys/class/drm" ];
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
        u2f = {
          bubblewrap.bind = {
            dev = [ "/dev/bus/usb" ] ++ (map (i: "/dev/hidraw" + toString i) (pkgs.lib.lists.range 0 20));
            rw = [ "/run/pcscd" ];
            ro = [
              "/sys/class/hidraw"
              "/sys/bus/hid"
              "/sys/devices"
              "/run/udev/data"
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

                  bubblewrap = {
                    # Base binds that everyone needs
                    bind.ro = [
                      "/etc/fonts"
                      "/etc/ssl/certs"
                      "/etc/profiles/per-user"
                      "/run/dbus"
                      (sloth.concat' sloth.homeDir "/.icons")
                    ];

                    # Deliberately NOT the whole $XDG_RUNTIME_DIR: it holds the
                    # raw session bus (bypassing nixpak's filtered xdg-dbus-proxy,
                    # which is on by default — grant names via dbus.policies),
                    # ssh-agent, gnupg and podman sockets. Presets bind the
                    # individual sockets an app needs. /doc is the document
                    # portal's FUSE mount: file-chooser results land there.
                    bind.rw = [
                      (sloth.concat' sloth.runtimeDir "/doc")
                      (sloth.mkdir (sloth.concat' sloth.homeDir "/.config/${configDir}"))
                      # Persistent per-app data/cache, the Flatpak layout
                      # (~/.var/app/<appId>/), since $HOME is otherwise a tmpfs.
                      # Load-bearing for secrets: inside the flatpak shim libsecret
                      # goes through the Secret portal, which keeps a per-app
                      # keyring file under $XDG_DATA_HOME — lose it and apps
                      # using it (Element's session-key safeStorage) start over.
                      [
                        (sloth.mkdir sloth.appDataDir)
                        sloth.xdgDataHome
                      ]
                      [
                        (sloth.mkdir sloth.appCacheDir)
                        sloth.xdgCacheHome
                      ]
                    ];

                    # Private /tmp instead of the host's shared one.
                    tmpfs = [ "/tmp" ];
                  };
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
      ${
        if resourceLimits != null then
          ''
            cat > $out/bin/${name} <<EOF
            #!/bin/sh
            exec /run/current-system/sw/bin/systemd-run --user --scope \\
              -p CPUQuota=${resourceLimits.cpu} \\
              -p MemoryMax=${resourceLimits.mem} \\
              --description="${name} (Restricted)" \\
              ${script}/bin/${executableName} "\$@"
            EOF
            chmod +x $out/bin/${name}
          ''
        else
          ''
            ln -s ${script}/bin/${executableName} $out/bin/${name}
          ''
      }

      for extraBin in ${toString extraBinNames}; do
        ln -s $out/bin/${name} $out/bin/$extraBin
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
