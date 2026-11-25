# nixpkgs' python builder now uses structured attrs, so makeWrapperArgs is no
# longer word-split and open-webui's "--set FRONTEND_BUILD_DIR <path>" reaches
# makeWrapper as one argument (build dies in fixup). Split it back into words.
# A no-op once NixOS/nixpkgs#575801 lands; drop this then.
_: prev: {
  open-webui = prev.open-webui.overridePythonAttrs (old: {
    makeWrapperArgs = prev.lib.concatMap (prev.lib.splitString " ") (old.makeWrapperArgs or [ ]);
  });
}
