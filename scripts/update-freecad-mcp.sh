#!/usr/bin/env bash
# Update the pinned freecad-mcp (neka-nat/freecad-mcp) source in mcp.nix to
# the latest tagged release.
#
# No upstream flake/PyPI package — vendored via fetchFromGitHub, pinned to a
# specific rev + hash + version literal. This tracks the latest git tag
# (not bare HEAD) for reproducibility. `nix-prefetch-url --unpack` against
# GitHub's archive tarball produces exactly the hash fetchFromGitHub expects
# (confirmed against the currently-pinned rev's known-correct hash), so no
# fake-hash/build-and-parse-the-error dance is needed here.
#
# Usage:  ./scripts/update-freecad-mcp.sh
# Deps:   bash, curl, jq, nix (nix-prefetch-url)
set -euo pipefail

cd "$(dirname "$0")/.."
PKG="mcp.nix"
REPO_SLUG="neka-nat/freecad-mcp"

log() { echo -e "\033[0;32m[INFO]\033[0m  $*" >&2; }
err() {
  echo -e "\033[0;31m[ERROR]\033[0m $*" >&2
  exit 1
}

# ── 1. Latest tag ─────────────────────────────────────────────────────────
TAGS_JSON=$(curl -fsSL "https://api.github.com/repos/${REPO_SLUG}/tags")
LATEST_TAG=$(jq -r '.[0].name' <<<"$TAGS_JSON")
LATEST_REV=$(jq -r '.[0].commit.sha' <<<"$TAGS_JSON")
[[ -n $LATEST_TAG && $LATEST_TAG != "null" ]] || err "Could not fetch latest tag"
LATEST="${LATEST_TAG#v}"

CURRENT=$(grep -oP 'version = "\K[^"]+' "$PKG" | head -1)
if [[ $CURRENT == "$LATEST" ]]; then
  log "freecad-mcp already at $LATEST — nothing to do."
  exit 0
fi
log "Updating $CURRENT → $LATEST ($LATEST_REV)"

# ── 2. Prefetch the new source hash ──────────────────────────────────────────
log "Fetching source hash..."
NEW_HASH=$(nix-prefetch-url --unpack \
  "https://github.com/${REPO_SLUG}/archive/${LATEST_REV}.tar.gz" 2>/dev/null | tail -1)
[[ -n $NEW_HASH ]] || err "Could not get source hash"
log "Source hash: $NEW_HASH"

# ── 3. Patch rev, hash, and version ──────────────────────────────────────────
CURRENT_REV=$(grep -oP 'rev = "\K[a-f0-9]{40}' "$PKG" | head -1)
CURRENT_HASH=$(grep -oP 'sha256 = "\K[^"]+' "$PKG" | head -1)

sed -i "s/rev = \"${CURRENT_REV}\"/rev = \"${LATEST_REV}\"/" "$PKG"
sed -i "s/sha256 = \"${CURRENT_HASH}\"/sha256 = \"${NEW_HASH}\"/" "$PKG"
sed -i "s/version = \"${CURRENT}\"/version = \"${LATEST}\"/" "$PKG"

# ── 4. Verify ────────────────────────────────────────────────────────────────
# Rebuild the actual buildPythonPackage output (not just the source fetch)
# standalone, matching mcp.nix's own expression, to catch real packaging
# breakage from the version bump (new/changed deps, hatchling metadata,
# etc.) — not just a bad hash.
log "Verifying build..."
nix build --impure --no-link --expr "
  let pkgs = import <nixpkgs> {};
  in pkgs.python3.pkgs.buildPythonPackage {
    pname = \"freecad-mcp\";
    version = \"${LATEST}\";
    pyproject = true;
    src = pkgs.fetchFromGitHub {
      owner = \"${REPO_SLUG%%/*}\";
      repo = \"${REPO_SLUG##*/}\";
      rev = \"${LATEST_REV}\";
      sha256 = \"${NEW_HASH}\";
    };
    nativeBuildInputs = [ pkgs.python3.pkgs.hatchling ];
    propagatedBuildInputs = with pkgs.python3.pkgs; [ mcp validators ];
    meta.mainProgram = \"freecad-mcp\";
  }"

log "Done. freecad-mcp $LATEST ($LATEST_REV) ready."
