# Called with python3.pkgs.callPackage. scripts/update-freecad-mcp.sh bumps
# version, rev and hash and builds this file, so it must stay self-contained.
{
  lib,
  buildPythonPackage,
  fetchFromGitHub,
  hatchling,
  mcp,
  validators,
}:

buildPythonPackage {
  pname = "freecad-mcp";
  version = "0.1.32";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "neka-nat";
    repo = "freecad-mcp";
    rev = "246f608d5de49089aadc41d2d91cfce2ad8a44cd";
    hash = "sha256-4BYPLCgQ6As1ceC5MUkfz5O8Lm+TbnSqiFZ8ffqD2uc=";
  };

  build-system = [ hatchling ];

  dependencies = [
    mcp
    validators
  ];

  # Upstream pins security floors (certifi, anyio, pyjwt) newer than nixpkgs
  # often ships; nixpkgs patches those itself, so take its versions.
  # no-link: upstream raises the floors on purpose and nixpkgs lags by design.
  pythonRelaxDeps = true;

  pythonImportsCheck = [ "freecad_mcp" ];

  meta = {
    description = "MCP server for driving FreeCAD from AI clients";
    homepage = "https://github.com/neka-nat/freecad-mcp";
    license = lib.licenses.mit;
    mainProgram = "freecad-mcp";
  };
}
