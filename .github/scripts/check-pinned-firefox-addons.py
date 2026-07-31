#!/usr/bin/env python3
# Bumps manually-pinned buildFirefoxXpiAddon entries in firefox-settings.nix
# to their latest AMO release. Extensions pulled from pkgs.nur.repos.rycee
# update via the normal `nix flake update` (rycee's repo regenerates hashes
# from AMO on its own schedule); the handful we pin by hand (obsidian web
# clipper, tab manager plus, ...) have no such upstream, so this script is
# their equivalent of that bot.
import json
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

SETTINGS_FILE = Path("firefox-settings.nix")

BLOCK_RE = re.compile(r"buildFirefoxXpiAddon\s*\{.*?\n  \};", re.DOTALL)
PNAME_RE = re.compile(r'pname = "([^"]+)";')
VERSION_RE = re.compile(r'version = "([^"]+)";')
ADDONID_RE = re.compile(r'addonId = "([^"]+)";')
URL_RE = re.compile(r'url = "([^"]+)";')
SHA256_RE = re.compile(r'sha256 = "([^"]+)";')


def amo_current_version(addon_id: str) -> tuple[str, str]:
    # Look up by guid (addonId), not by a slug guessed from pname: AMO slugs
    # aren't unique to "the" addon you mean — obsidian-web-clipper the slug
    # resolves to an unrelated addon, while the guid always identifies the
    # exact listing pinned in this file.
    quoted = urllib.parse.quote(addon_id, safe="")
    req = urllib.request.Request(
        f"https://addons.mozilla.org/api/v5/addons/addon/{quoted}/",
        headers={"User-Agent": "nix-presets-maintain-bot"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.load(resp)
    current = data["current_version"]
    return current["version"], current["file"]["url"]


def nix_prefetch_sha256(url: str) -> str:
    lines = (
        subprocess.run(
            ["nix-prefetch-url", url], capture_output=True, text=True, check=True
        )
        .stdout.strip()
        .splitlines()
    )
    return lines[-1]


def main() -> int:
    text = SETTINGS_FILE.read_text()
    changed = False

    for block in BLOCK_RE.findall(text):
        pname = PNAME_RE.search(block).group(1)
        addon_id = ADDONID_RE.search(block).group(1)
        pinned_version = VERSION_RE.search(block).group(1)

        try:
            latest_version, latest_url = amo_current_version(addon_id)
        except Exception as exc:
            print(f"::warning::{pname}: could not query AMO ({exc}), skipping")
            continue

        if latest_version == pinned_version:
            print(f"{pname}: up to date ({pinned_version})")
            continue

        print(f"{pname}: {pinned_version} -> {latest_version}")
        try:
            new_sha256 = nix_prefetch_sha256(latest_url)
        except Exception as exc:
            print(
                f"::warning::{pname}: could not prefetch {latest_url} ({exc}), skipping"
            )
            continue

        new_block = block
        new_block = VERSION_RE.sub(f'version = "{latest_version}";', new_block, count=1)
        new_block = URL_RE.sub(f'url = "{latest_url}";', new_block, count=1)
        new_block = SHA256_RE.sub(f'sha256 = "{new_sha256}";', new_block, count=1)

        text = text.replace(block, new_block, 1)
        changed = True

    if changed:
        SETTINGS_FILE.write_text(text)

    return 0


if __name__ == "__main__":
    sys.exit(main())
