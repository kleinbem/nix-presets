#!/usr/bin/env bash
set -e

ROOT_DIR=".."
FLAKE_FILE="$ROOT_DIR/flake.nix"

get_latest_asset() {
  repo=$1
  resp=$(curl -s "https://api.github.com/repos/$repo/releases")
  echo "$resp" | grep -o 'https://[^"]*\.zip' | head -n 1
}

echo "Updating GApps URLs..."
# ARM64: MindTheGapps
URL_ARM64=$(get_latest_asset "MindTheGapps/16.0.0-arm64")
if [ -n "$URL_ARM64" ]; then
  sed -i "s|url = \"https://github.com/MindTheGapps/16.0.0-arm64/.*\"|url = \"$URL_ARM64\"|" "$FLAKE_FILE"
fi

# x86_64: BiTGApps (Placeholder)
# Note: No programmatic way to fetch stable Android 16 x86_64 GApps yet.
# Leaving flake.nix input as is (user must update manually).
echo "Skipping x86_64 GApps update (Manual intervention required as per README)."

echo "Updating Flake Inputs..."
git -C "$ROOT_DIR" add flake.nix
(cd "$ROOT_DIR" && nix flake update)

echo "Updating Redroid Docker Images..."
IMAGE="redroid/redroid"
TAG="16.0.0_64only-latest"

update_docker() {
  arch=$1
  sed_digest=$2
  sed_sha=$3
  
  echo "Fetching $IMAGE:$TAG ($arch)..."
  # Use nix-prefetch-docker
  json=$(nix run nixpkgs#nix-prefetch-docker -- --image-name "$IMAGE" --image-tag "$TAG" --os linux --arch "$arch" --json)
  digest=$(echo "$json" | grep -oP '"imageDigest": "\K[^"]+')
  sha=$(echo "$json" | grep -oP '"sha256": "\K[^"]+')
  
  if [ -n "$digest" ] && [ -n "$sha" ]; then
    echo "Updating $arch: $digest"
    # Replace content. Match the comment markers.
    sed -i "s|imageDigest = \".*\"; # $sed_digest|imageDigest = \"$digest\"; # $sed_digest|" "$FLAKE_FILE"
    sed -i "s|sha256 = \".*\"; # $sed_sha|sha256 = \"$sha\"; # $sed_sha|" "$FLAKE_FILE"
  else
    echo "Error fetching $arch image"
  fi
}

update_docker "arm64" "REPLACE_DIGEST_ARM64" "REPLACE_SHA256_ARM64"
update_docker "amd64" "REPLACE_DIGEST_AMD64" "REPLACE_SHA256_AMD64"

echo "Done."
