#!/usr/bin/env python3
import json
import os
import sys
import subprocess
import time
import argparse
from typing import Dict, Any

# ATLAS - Unified Nix Workspace Toolkit
# V1.1.0 - Nix-Native Migration

# --- STYLING ---
BLUE, BOLD, NC = '\033[0;34m', '\033[1m', '\033[0m'
GREEN, YELLOW, RED = '\033[0;32m', '\033[0;33m', '\033[0;31m'
MAGENTA, CYAN = '\033[0;35m', '\033[0;36m'

def log(msg, color=BLUE):
    print(f"{color}{BOLD}[atlas]{NC} {msg}", file=sys.stderr)

# --- CORE ENGINE ---
class AtlasEngine:
    def __init__(self, flake_root="/home/martin/Develop/github.com/kleinbem/nix"):
        self.flake_root = flake_root

    def nix_eval(self, expr):
        """Evaluates a Nix expression against the host config."""
        try:
            # Modern Flake evaluation syntax
            attr_path = f".#nixosConfigurations.nixos-nvme.config.{expr}"
            result = subprocess.run(
                ["nix", "eval", "--json", "--impure", attr_path],
                capture_output=True, text=True, check=True,
                cwd=self.flake_root
            )
            return json.loads(result.stdout)
        except subprocess.CalledProcessError as e:
            log(f"Nix evaluation failed: {e.stderr}", RED)
            return {"error": e.stderr}
        except Exception as e:
            log(f"Evaluation error: {str(e)}", RED)
            return {"error": str(e)}

    def get_secret(self, key):
        """Fetches a secret. First checks decrypted paths (avoiding YubiKey prompts), then falls back to SOPS."""
        # 1. Check NixOS system-level sops path
        sys_path = f"/run/secrets/{key}"
        if os.path.exists(sys_path) and os.access(sys_path, os.R_OK):
            try:
                with open(sys_path, "r") as f:
                    content = f.read().strip()
                    if content:
                        return content
            except Exception:
                pass

        # 2. Check Home Manager sops-nix path
        user_path = os.path.expanduser(f"~/.config/sops-nix/secrets/{key}")
        if os.path.exists(user_path) and os.access(user_path, os.R_OK):
            try:
                with open(user_path, "r") as f:
                    content = f.read().strip()
                    if content:
                        return content
            except Exception:
                pass

        # 3. Fall back to running SOPS CLI
        try:
            # Use the centralized nix-secrets repository
            secrets_path = f"{self.flake_root}/nix-secrets/secrets.yaml"
            result = subprocess.run(
                ["sops", "--decrypt", "--extract", f'["{key}"]', secrets_path],
                capture_output=True, text=True, check=True
            )
            return result.stdout.strip()
        except Exception as e:
            log(f"Failed to fetch secret {key}: {e}", RED)
            return None

# --- AUTH MODULE ---
class GitHubAuth:
    @staticmethod
    def get_short_lived_token(engine: AtlasEngine):
        """Exchanges App Identity for a 1-hour Installation Token."""
        try:
            import requests
            from authlib.jose import jwt
            
            app_id = engine.get_secret("github_app_id")
            install_id = engine.get_secret("github_app_installation_id")
            priv_key = engine.get_secret("github_app_private_key")

            if not all([app_id, install_id, priv_key]):
                log("GitHub App Identity not found in SOPS. Falling back to PAT...", YELLOW)
                return engine.get_secret("github_pat")

            now = int(time.time())
            payload = {"iat": now - 60, "exp": now + 600, "iss": app_id}
            token = jwt.encode({"alg": "RS256"}, payload, priv_key).decode("utf-8")

            url = f"https://api.github.com/app/installations/{install_id}/access_tokens"
            headers = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"}
            
            resp = requests.post(url, headers=headers)
            return resp.json()["token"]
        except ImportError:
            log("Auth libraries not found. Run via 'nix run .#atlas' for the full environment.", RED)
            return None

# --- COMMANDS ---
def cmd_status(engine: AtlasEngine):
    log("Mapping system fleet state...")
    containers = engine.nix_eval("my.containers")
    
    print(f"\n{BLUE}{BOLD}==================== SANCTUARY FLEET STATUS ===================={NC}")
    print(f"{'Container':<18} | {'Status':<10} | {'Profile':<12} | {'Endpoint':<20}")
    print(f"{'-'*18}-+-{'-'*10}-+-{'-'*12}-+-{'-'*20}")

    for name, cfg in sorted(containers.items()):
        if "error" in containers: break
        
        # Systemd Check
        unit = f"container@{name}.service"
        active = subprocess.run(["systemctl", "is-active", unit], capture_output=True, text=True).stdout.strip()
        
        color = GREEN if active == "active" else NC
        status = "RUNNING" if active == "active" else "Stopped"
        
        # Logical Profile Mapping
        if name in ["ollama", "n8n", "agent-team"]: tag = f"{MAGENTA}AI/WORK{NC}"
        elif cfg.get("enable", False): tag = f"{BLUE}CORE{NC}"
        else: tag = f"{NC}WORKLOAD{NC}"

        endpoint = f"https://{name}.local" if active == "active" else "---"
        print(f"{color}{name:<18}{NC} | {color}{status:<10}{NC} | {tag:<21} | {endpoint}")
    print(f"{BLUE}{BOLD}================================================================${NC}\n")

def cmd_mcp_launch(engine: AtlasEngine, server, command):
    log(f"Securely launching MCP server: {server}")
    env = os.environ.copy()
    
    if server == "github":
        token = GitHubAuth.get_short_lived_token(engine)
        if token: env["GITHUB_PERSONAL_ACCESS_TOKEN"] = token
    elif server == "brave-search":
        key = engine.get_secret("brave_api_key")
        if key: env["BRAVE_API_KEY"] = key

    subprocess.run(command, env=env)

def main():
    engine = AtlasEngine()
    parser = argparse.ArgumentParser(prog="atlas", description="Sanctuary Workspace Toolkit")
    subparsers = parser.add_subparsers(dest="command")

    subparsers.add_parser("status", help="Show system service status")
    
    mcp = subparsers.add_parser("mcp", help="MCP management")
    mcp_sub = mcp.add_subparsers(dest="sub")
    
    launch = mcp_sub.add_parser("launch", help="Securely launch an MCP server")
    launch.add_argument("server", choices=["github", "brave-search", "filesystem", "atlas"])
    launch.add_argument("exec", nargs=argparse.REMAINDER)

    args = parser.parse_args()
    if args.command == "status": cmd_status(engine)
    elif args.command == "mcp" and args.sub == "launch": cmd_mcp_launch(engine, args.server, args.exec)
    else: parser.print_help()

if __name__ == "__main__":
    main()
