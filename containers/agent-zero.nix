{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.containers.agent-zero;
  mkContainer = self.lib.mkContainer;
  tlsOpts = import ../lib/tls-options.nix { inherit lib; };

  # System packages needed inside the container for building Python native extensions
  buildDeps = with pkgs; [
    python3
    python3Packages.pip
    python3Packages.virtualenv
    git
    gcc
    gnumake
    pkg-config
    openssl
    openssl.dev
    zlib
    zlib.dev
    libffi
    libffi.dev
    curl
    wget
    poppler_utils # pdf2image
    tesseract     # pytesseract OCR
    ffmpeg        # whisper audio
    sox           # audio processing
    cacert
  ];
in
{
  options.my.containers.agent-zero = {
    enable = lib.mkEnableOption "Agent Zero AI Framework Container";
    ip = lib.mkOption { type = lib.types.str; };
    hostDataDir = lib.mkOption { type = lib.types.str; };
    ollamaUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "URL of the Ollama API endpoint.";
    };
    memoryLimit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "4G";
    };
    secretsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path on the host to environment file containing API keys (e.g. OPENAI_API_KEY).";
    };
  } // tlsOpts;

  config = lib.mkIf cfg.enable (mkContainer { inherit config;
    name = "agent-zero";
    cfg = cfg;
    innerConfig = {
      environment.systemPackages = buildDeps;

      # Ensure SSL certificates are available for pip / git
      environment.variables = {
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        GIT_SSL_CAINFO = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        REQUESTS_CA_BUNDLE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      };

      systemd.services.agent-zero = {
        description = "Agent Zero AI Framework";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];

        environment = {
          HOME = "/var/lib/agent-zero";
          A0_SET_CHAT_MODEL_PROVIDER = "ollama";
          A0_SET_CHAT_MODEL_NAME = "llama3.1";
          A0_SET_UTILITY_MODEL_PROVIDER = "ollama";
          A0_SET_UTILITY_MODEL_NAME = "llama3.1";
          A0_SET_EMBEDDING_MODEL_PROVIDER = "ollama";
          A0_SET_EMBEDDING_MODEL_NAME = "nomic-embed-text";
        } // lib.optionalAttrs (cfg.ollamaUrl != "") {
          A0_SET_CHAT_MODEL_URL = cfg.ollamaUrl;
          A0_SET_UTILITY_MODEL_URL = cfg.ollamaUrl;
          A0_SET_EMBEDDING_MODEL_URL = cfg.ollamaUrl;
        };

        path = buildDeps;

        serviceConfig = {
          Type = "simple";
          WorkingDirectory = "/var/lib/agent-zero/app";
          Restart = "on-failure";
          RestartSec = "10s";
          EnvironmentFile = lib.mkIf (cfg.secretsFile != null) "/run/secrets/agent-zero.env";
        };

        script = ''
          set -euo pipefail
          APP_DIR="/var/lib/agent-zero/app"
          VENV_DIR="/var/lib/agent-zero/venv"

          # Clone on first run
          if [ ! -d "$APP_DIR/.git" ]; then
            echo "Cloning Agent Zero..."
            ${pkgs.git}/bin/git clone --depth 1 https://github.com/agent0ai/agent-zero.git "$APP_DIR"
          fi

          # Create/update venv
          if [ ! -d "$VENV_DIR" ]; then
            echo "Creating Python venv..."
            ${pkgs.python3}/bin/python3 -m venv "$VENV_DIR"
          fi

          # Install/update dependencies
          echo "Installing dependencies..."
          "$VENV_DIR/bin/pip" install --quiet --upgrade pip
          "$VENV_DIR/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"

          echo "Starting Agent Zero on port 50001..."
          cd "$APP_DIR"
          exec "$VENV_DIR/bin/python" run_ui.py --port 50001 --host 0.0.0.0
        '';
      };

      networking.firewall.allowedTCPPorts = [ 50001 ];
    };
    bindMounts = {
      "/var/lib/agent-zero" = {
        hostPath = cfg.hostDataDir;
        isReadOnly = false;
      };
    } // lib.optionalAttrs (cfg.secretsFile != null) {
      "/run/secrets/agent-zero.env" = {
        hostPath = cfg.secretsFile;
        isReadOnly = true;
      };
    };
  });
}
