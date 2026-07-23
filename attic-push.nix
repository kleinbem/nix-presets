{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.my.attic-push;
in
{
  options.my.attic-push = {
    enable = lib.mkEnableOption "Automatically push locally built derivations to Attic (post-build-hook)";

    tokenFile = lib.mkOption {
      type = lib.types.str;
      description = "Path to the secret file containing the Attic push token";
    };
  };

  config = lib.mkIf cfg.enable {
    # Systemd oneshot to ensure the root user is authenticated with Attic
    # since the post-build-hook runs as root.
    systemd.services.attic-login = {
      description = "Authenticate Attic client for root (for post-build-hook)";
      wantedBy = [ "multi-user.target" ];
      # Run after sops-nix has decrypted the secrets
      after = [ "sops-nix.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        export HOME=/root
        mkdir -p /root/.config/attic
        ${pkgs.attic-client}/bin/attic login kleinbem https://cache.kleinbem.dev $(cat ${cfg.tokenFile})
      '';
    };

    # The actual hook script
    environment.etc."nix/upload-to-cache.sh" = {
      mode = "0755";
      text = ''
        #!/bin/sh
        set -eu
        set -f # disable globbing
        export IFS=' '

        # Output is sent to the nix-daemon log (journalctl -u nix-daemon)
        echo "Pushing paths to Attic: $OUT_PATHS"

        # Push ONLY the freshly-built outputs, never their closure (--no-closure).
        # $OUT_PATHS is what this build just produced locally — by definition it
        # was built, not substituted, so it belongs in Attic. Without
        # --no-closure, attic re-closes over each output and drags in its deps;
        # its built-in filter only skips cache.nixos.org, so cachix deps leak in.
        # Every locally-built dep was itself an $OUT_PATHS at its own build step,
        # so per-output pushes still cover the full built set — as a SPARSE
        # OVERLAY (see nix-presets/containers/attic.nix), not a closure mirror.
        export HOME=/root
        exec ${pkgs.attic-client}/bin/attic push --no-closure system $OUT_PATHS
      '';
    };

    # Configure the Nix daemon to use the hook
    nix.settings.post-build-hook = "/etc/nix/upload-to-cache.sh";
  };
}
