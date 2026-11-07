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
  version = "0.1.30";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "neka-nat";
    repo = "freecad-mcp";
    rev = "ec8abf21fb9e9ed4bbcbba497515e088423ad251";
    hash = "sha256-PkRT0avZ9Wh2dEUN5+YAfp0I5eI8cfEpcEjv94YQu7U=";
  };

  build-system = [ hatchling ];

  dependencies = [
    mcp
    validators
  ];

  # Upstream pins security floors (certifi, anyio, pyjwt) newer than nixpkgs
  # often ships; nixpkgs patches those itself, so take its versions.
  pythonRelaxDeps = true;

  pythonImportsCheck = [ "freecad_mcp" ];

  meta = {
    description = "MCP server for driving FreeCAD from AI clients";
    homepage = "https://github.com/neka-nat/freecad-mcp";
    license = lib.licenses.mit;
    mainProgram = "freecad-mcp";
  };
}
