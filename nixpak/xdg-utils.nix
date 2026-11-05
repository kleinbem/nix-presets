{ pkgs, ... }:

let
  # Hands the URI to xdg-desktop-portal, which opens it with the host's
  # default handler (outside the sandbox). gdbus rather than dbus-send:
  # dbus-send can't encode the (empty) a{sv} options argument OpenURI takes.
  # URIs only — local files would need OpenFile, which takes an fd.
  # https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.OpenURI.html
  mkSandboxedXdgUtils = pkgs.writeShellScriptBin "xdg-open" ''
    if [ -z "$1" ]; then
      echo "Usage: xdg-open <uri>" >&2
      exit 1
    fi

    exec ${pkgs.glib.bin}/bin/gdbus call --session \
      --dest org.freedesktop.portal.Desktop \
      --object-path /org/freedesktop/portal/desktop \
      --method org.freedesktop.portal.OpenURI.OpenURI \
      "" "$1" "{}" >/dev/null
  '';
in
pkgs.symlinkJoin {
  name = "sandboxed-xdg-utils";
  paths = [
    mkSandboxedXdgUtils
    pkgs.xdg-utils
  ];
}
