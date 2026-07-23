{ self }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.containers.frigate;
  inherit (self.lib) mkContainer;

  # On Jetson we do NOT use the desktop DRI render node (/dev/dri/renderD128);
  # the iGPU + NVDEC are reached through the Tegra /dev/nvhost-* + /dev/nvmap
  # nodes below. VAAPI is likewise a desktop path and must be off on Tegra.
  useDesktopGpu = cfg.enableGPU && !cfg.jetson;

  # Expose each Tegra node into the container's /dev (nspawn --bind). cgroup
  # access is granted separately via extraAllowedDevices. Gated on cfg.jetson
  # so non-Jetson hosts (and the x86 container-factory) never see these.
  jetsonBinds = lib.optionalAttrs cfg.jetson (
    lib.listToAttrs (
      map (
        d:
        lib.nameValuePair d {
          hostPath = d;
          isReadOnly = false;
        }
      ) cfg.jetsonDevices
    )
  );
in
{
  options.my.containers.frigate = {
    enable = lib.mkEnableOption "Frigate Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/frigate";
    };
    mediaDir = lib.mkOption {
      type = lib.types.str;
      description = "Path to the dedicated Frigate storage SSD.";
      default = "/mnt/frigate";
    };
    enableGPU = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    enableHailo = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    detector = lib.mkOption {
      type = lib.types.enum [
        "cpu"
        "hailo"
        "tensorrt"
      ];
      default = "cpu";
    };
    jetson = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Target an NVIDIA Jetson (Tegra) host. Passes the Tegra device set
        (jetsonDevices) instead of the desktop DRI render node so the
        TensorRT detector can reach the iGPU, and disables the desktop VAAPI
        driver. NOTE: hardware video decode (NVDEC) is NOT enabled by this —
        jetpack-nixos ships no h264_nvmpi ffmpeg, so decode stays on CPU
        until an L4T ffmpeg is packaged (Phase 2). Detector runs on the GPU;
        decode on the CPU.
      '';
    };
    jetsonDevices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/dev/nvhost-ctrl"
        "/dev/nvhost-ctrl-gpu"
        "/dev/nvhost-gpu"
        "/dev/nvhost-as-gpu"
        "/dev/nvhost-prof-gpu"
        "/dev/nvhost-nvdec"
        "/dev/nvhost-vic"
        "/dev/nvhost-nvjpg"
        "/dev/nvmap"
      ];
      description = ''
        Tegra /dev nodes exposed to the container when jetson = true. VALIDATE
        on the real Orin before enabling — the exact set varies by L4T release
        (JetPack 6 / r36 may expose CUDA via /dev/nvgpu/igpu0/* instead of some
        of these). Check with `ls -la /dev/nvhost* /dev/nvmap /dev/nvgpu` on the
        device and trim/extend this list. Binding a node that does not exist on
        the host fails container start (not the build).
      '';
    };
    innerConfig = lib.mkOption {
      type = lib.types.deferredModule;
      default = { };
      description = "Extra NixOS configuration to inject into the container.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "3G";
      description = "systemd MemoryMax for the container (e.g. \"3G\"). null = unbounded.";
    };
    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/frigate_rtsp_env";
      description = ''
        Host path to an env-file (KEY=value lines) bind-mounted read-only into the
        container at the same path and set as the Frigate service's
        EnvironmentFile. Frigate substitutes {VAR} in its config from these — use
        it for camera RTSP credentials sourced from a sops secret, never inline in
        the config. null = no env-file.
      '';
    };
  };

  config = lib.mkIf cfg.enable (mkContainer {
    inherit config;
    name = "frigate";
    enableGPU = useDesktopGpu;
    cfg = cfg // {
      extraAllowedDevices =
        (lib.optionals (cfg.detector == "hailo") [
          {
            node = "/dev/hailo0";
            modifier = "rw";
          }
        ])
        # cgroup permission for each Tegra node (the bind only makes it visible)
        ++ (lib.optionals cfg.jetson (
          map (d: {
            node = d;
            modifier = "rw";
          }) cfg.jetsonDevices
        ));
    };
    innerConfig = {
      imports = [
        {
          services.frigate = {
            enable = true;
            hostname = "frigate";
            # VAAPI is a desktop path; on Jetson it must stay null (Tegra decode
            # is nvv4l2/nvmpi, wired separately in Phase 2).
            vaapiDriver = if useDesktopGpu then "nvidia" else null;
            settings = {
              cameras = { };
              detectors = {
                main = {
                  type =
                    if cfg.detector == "tensorrt" then
                      "tensorrt"
                    else if cfg.detector == "hailo" then
                      "hailo"
                    else
                      "cpu";
                  device = if cfg.detector == "tensorrt" then "0" else null;
                };
              };
            };
          };
          networking.firewall.allowedTCPPorts = [
            5000
            8554
            8555
          ];
          networking.firewall.allowedUDPPorts = [ 8555 ];
          # Camera RTSP creds (and any other {VAR}s) come from the host env-file
          # bound in below — Frigate does {VAR} substitution from its environment.
          systemd.services.frigate.serviceConfig.EnvironmentFile = lib.mkIf (
            cfg.environmentFile != null
          ) cfg.environmentFile;
        }
        cfg.innerConfig
      ];
    };
    bindMounts = {
      "/var/lib/frigate" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
      "/var/lib/frigate/cache" = {
        hostPath = "/var/lib/frigate/cache";
        isReadOnly = false;
      };
      "/media/frigate" = {
        hostPath = cfg.mediaDir;
        isReadOnly = false;
      };
    }
    // jetsonBinds
    # Bind the host env-file (e.g. a sops-decrypted /run/secrets/…) into the
    # container at the same path so EnvironmentFile above can read it.
    // lib.optionalAttrs (cfg.environmentFile != null) {
      ${cfg.environmentFile} = {
        hostPath = cfg.environmentFile;
        isReadOnly = true;
      };
    };
  });
}
