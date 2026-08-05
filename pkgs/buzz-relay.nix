# buzz-relay — WebSocket relay server for Block's Buzz (Nostr-based team
# chat + git + AI-agent workspace, https://github.com/block/buzz).
#
# No upstream flake/nixosModule exists yet (10 days old at packaging time),
# so this builds straight from the Cargo workspace, matching the upstream
# Dockerfile's own build recipe (cargo build --release --locked -p buzz-relay
# --bin buzz-relay) — only the relay binary, not buzz-admin/buzz-pair-relay/
# CLI/desktop/web, which we don't need for a headless self-hosted relay.
#
# cargoLock.lockFile points at a vendored copy (./buzz-Cargo.lock), NOT
# "${src}/Cargo.lock". Pointing at the fetched src forces Nix to realize the
# fetchFromGitHub derivation at EVAL time (IFD) so it can read the file — and
# that derivation is pinned to the evaluating pkgs' system, which breaks
# cross-arch eval (e.g. nix-config's container-manifest promote job evaluates
# an x86_64-linux container-factory from an aarch64-linux runner with no
# foreign builder configured: "platform mismatch", confirmed 2026-08-02). A
# plain repo-relative path is read directly, no IFD, no arch pinning.
#
# Update by bumping `rev`/`hash` to a newer commit, re-fetching
# buzz-Cargo.lock from that same rev (it MUST match the source tree's actual
# Cargo.lock — a stale copy fails the build's own lock check), and
# re-deriving the two `outputHashes` (git dependencies: mesh-llm, and a Block
# fork of rust-s3) the standard way — set to lib.fakeHash, build, take the
# "got:" hash from the mismatch error.
{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  openssl,
}:

rustPlatform.buildRustPackage rec {
  pname = "buzz-relay";
  version = "0.2.0";

  src = fetchFromGitHub {
    owner = "block";
    repo = "buzz";
    rev = "10d5a26414dc90dc89fd27de74b21e105d4fa622"; # main, 2026-07-31
    hash = "sha256-wmcZXyfHClBbKBG1HPVJcKPvY/kbigS/YNyUPepU3JI=";
  };

  cargoLock = {
    lockFile = ./buzz-Cargo.lock;
    outputHashes = {
      # All mesh-llm-* crates share one git source; any single package from
      # it identifies the fetch for importCargoLock.
      "mesh-llm-api-client-0.74.0" = "sha256-nkt/bTHvc7ACAP2Gx/Px/hGad5ryzWn2eA9isXKF05s=";
      "aws-creds-0.39.1" = "sha256-QAAm1phmeLFtDRgfDCoHijN1ce/rYzh18KziOUbL+hw=";
    };
  };

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];

  cargoBuildFlags = [
    "-p"
    "buzz-relay"
    "--bin"
    "buzz-relay"
  ];

  # Full workspace test suite needs the live Postgres/Redis/Typesense/S3
  # stack this derivation doesn't have — covered by integration testing at
  # the container level instead.
  doCheck = false;

  meta = {
    description = "WebSocket relay server for the Buzz communications platform";
    homepage = "https://github.com/block/buzz";
    license = lib.licenses.asl20;
    mainProgram = "buzz-relay";
  };
}
