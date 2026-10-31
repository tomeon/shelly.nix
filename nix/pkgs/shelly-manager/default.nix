{sources}: {
  lib,
  newScope,
  ...
}:
lib.makeScope newScope (scope: {
  shelly-manager = scope.callPackage ({
    python3Packages,
    shelly-manager-api,
    shelly-manager-cli,
    shelly-manager-core,
    shelly-manager-web,
    ...
  }:
    python3Packages.buildPythonApplication {
      inherit (sources.shelly-manager) pname src;
      version = lib.removePrefix "v" sources.shelly-manager.version;
      pyproject = true;
      build-system = with python3Packages; [setuptools];
      propagatedBuildInputs = [shelly-manager-core];
      checkDepends = with python3Packages; [
        pytest
        pytest-asyncio
        pytest-cov
        black
        ruff
        mypy
        types-pyyaml
      ];
      passthru = {
        api = shelly-manager-api;
        cli = shelly-manager-cli;
        core = shelly-manager-core;
        web = shelly-manager-web;
      };
    }) {};

  shelly-manager-api = scope.callPackage ({
    python3Packages,
    lib,
    testers,
    shelly-manager,
    shelly-manager-core,
    ...
  }:
    python3Packages.buildPythonApplication (finalAttrs: {
      inherit (shelly-manager) src version;
      pname = "${lib.getName shelly-manager}-api";
      sourceRoot = "${finalAttrs.src.name}/packages/api";
      pyproject = true;
      pythonRelaxDeps = true;
      build-system = with python3Packages; [setuptools];
      propagatedBuildInputs =
        (with python3Packages; [
          apscheduler
          litestar
          uvicorn
        ])
        ++ [
          shelly-manager-core
        ];
      checkDepends = with python3Packages; [
        pytest
        pytest-asyncio
        pytest-cov
        black
        ruff
        mypy
      ];
      postInstall = ''
        script=$out/bin/shelly-manager-api
        mkdir -p "''${script%/*}"
        cat > "$script" <<'SCRIPT'
        #!/usr/bin/env python3
        import sys
        from uvicorn.main import main
        main(["api.main:app_factory", "--factory", *sys.argv[1:]], prog_name="shelly-manager-api")
        SCRIPT
        chmod +x "$script"
      '';
      passthru = {
        tests = {
          api = testers.runNixOSTest {
            nodes.api = _: {
            };
          };
        };
      };
    })) {};

  shelly-manager-cli = scope.callPackage ({
    python3Packages,
    shelly-manager,
    shelly-manager-core,
    ...
  }:
    python3Packages.buildPythonApplication (finalAttrs: {
      inherit (shelly-manager) src version;
      pname = "${lib.getName shelly-manager}-cli";
      sourceRoot = "${finalAttrs.src.name}/packages/cli";
      pyproject = true;
      build-system = with python3Packages; [setuptools];
      pythonRelaxDeps = true;
      propagatedBuildInputs =
        (with python3Packages; [
          click
          rich
        ])
        ++ [shelly-manager-core];
      checkDepends = with python3Packages; [
        pytest
        pytest-asyncio
        pytest-cov
        black
        ruff
        mypy
        types-pyyaml
      ];
    })) {};

  shelly-manager-core = scope.callPackage ({
    python3Packages,
    shelly-manager,
    ...
  }:
    python3Packages.buildPythonApplication (finalAttrs: {
      inherit (shelly-manager) src version;
      pname = "${lib.getName shelly-manager}-core";
      sourceRoot = "${finalAttrs.src.name}/packages/core";
      pyproject = true;
      pythonRelaxDeps = true;
      build-system = with python3Packages; [setuptools];
      propagatedBuildInputs = with python3Packages; [
        pydantic
        pydantic-settings
        structlog
        httpx
        zeroconf
        sqlalchemy
        aiosqlite
        cryptography
      ];
    })) {};

  shelly-manager-web = scope.callPackage ({
    buildNpmPackage,
    lib,
    writeText,
    shelly-manager,
    viteBaseApiUrl ? "http://localhost:8000",
    ...
  }: let
    npmDepsHashes = {
      "1.10.0" = "sha256-a5aUs/P5hF5du8qXWZ5oajNz7zIViTdfo5jompcSXXw=";
    };
  in
    buildNpmPackage (finalAttrs: let
      configJs = writeText "shelly-manager-web-config.js" ''
        window._env = ${lib.toJSON {
          VITE_BASE_API_URL = finalAttrs.viteBaseApiUrl;
        }};
      '';
    in {
      inherit viteBaseApiUrl;
      inherit (shelly-manager) src version;
      pname = "${lib.getName shelly-manager}-web";
      sourceRoot = "${finalAttrs.src.name}/packages/web";
      npmDepsHash = npmDepsHashes.${finalAttrs.version} or lib.fakeHash;
      postInstall = ''
        ln -sfT ${configJs} $out/lib/node_modules/web/public/config.js
      '';
    })) {};
})
