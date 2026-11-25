{ pkgs }:
let
  extensions = import ./extensions.nix { inherit pkgs; };
  mkBundle =
    name: exts:
    pkgs.symlinkJoin {
      name = "${name}-extensions-bundle";
      paths = exts;
    };
in
{
  antigravity = mkBundle "antigravity" (extensions.common ++ extensions.ai ++ extensions.vscodeExtra);
  cursor = mkBundle "cursor" (extensions.common ++ extensions.ai ++ extensions.cursorExtra);
  windsurf = mkBundle "windsurf" (extensions.common ++ extensions.ai);
}
