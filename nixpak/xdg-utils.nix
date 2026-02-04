{ pkgs, ... }:

let
  mkSandboxedXdgUtils = pkgs.writeShellScriptBin "xdg-open" ''
    # Using dbus-send to communicate with xdg-desktop-portal
    # https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.OpenURI.html

    LOGFILE="/tmp/xdg-open-debug.log"
    echo "--- xdg-open called at $(date) ---" >> "$LOGFILE"
    echo "Args: $@" >> "$LOGFILE"
    echo "DBUS_SESSION_BUS_ADDRESS: $DBUS_SESSION_BUS_ADDRESS" >> "$LOGFILE"

    if [ -z "$1" ]; then
      echo "Usage: xdg-open <url>"
      exit 1
    fi

    ${pkgs.dbus}/bin/dbus-send \
      --session \
      --print-reply \
      --dest=org.freedesktop.portal.Desktop \
      /org/freedesktop/portal/desktop \
      org.freedesktop.portal.OpenURI.OpenURI \
      string:"" \
      string:"$1" \
      array:dict:string:variant: >> "$LOGFILE" 2>&1
  '';
in
pkgs.symlinkJoin {
  name = "sandboxed-xdg-utils";
  paths = [
    mkSandboxedXdgUtils
    pkgs.xdg-utils
  ];
}
