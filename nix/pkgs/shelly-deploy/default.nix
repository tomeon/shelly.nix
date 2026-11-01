{
  lib,
  python3Packages,
  shelly-manager-core,
}:
python3Packages.buildPythonApplication {
  pname = "shelly-deploy";
  version = "0.1.0";
  pyproject = true;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./pyproject.toml
      (lib.fileset.fileFilter (file: file.hasExt "py") ./src)
      (lib.fileset.fileFilter (file: file.hasExt "py") ./tests)
    ];
  };

  build-system = [python3Packages.setuptools];
  dependencies = [shelly-manager-core];
  nativeCheckInputs = [python3Packages.pytestCheckHook];
  pythonImportsCheck = ["shelly_deploy"];

  passthru = {
    # The fake device the tests use, for NixOS VM tests.
    fakeDevice = ./tests/fake_shelly.py;
  };

  meta = {
    description = "Deploy declarative Shelly device configurations";
    longDescription = ''
      Applies the manifest produced by shelly.nix's Shelly module to Shelly
      Gen2+ devices over their local RPC interface, using shelly-manager-core.
      `shelly-deploy diff` shows what would change; `shelly-deploy switch`
      applies it, reboots devices that need it, and checks the result.
    '';
    mainProgram = "shelly-deploy";
    platforms = lib.platforms.unix;
  };
}
