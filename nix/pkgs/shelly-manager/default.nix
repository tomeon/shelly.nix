{sources}: {
  lib,
  newScope,
  ...
}: let
  upstream = sources.shelly-manager;
in
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
        inherit (upstream) pname src;
        version = lib.removePrefix "v" upstream.version;
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
        meta = {
          homepage = "https://github.com/${upstream.src.owner}/${upstream.src.repo}";
          changelog = "https://github.com/${upstream.src.owner}/${upstream.src.repo}/releases/tag/${upstream.version}";
          license = lib.licenses.mit;
          platforms = lib.platforms.unix;
          description = "Local management for Shelly IoT devices without cloud connectivity";
          longDescription = ''
            Manage Shelly devices on your local network without connecting them to
            the Shelly Cloud. Supports Gen1 (legacy HTTP) and Gen2 (RPC) devices:
            discover devices via mDNS or network scanning, manage firmware updates
            (including for devices with no internet access), export and apply
            configuration in bulk, take encrypted per-device backups, and monitor
            status. Available as a web interface, a command line tool and a REST
            API, provided by the passthru sub-packages.
          '';
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
        meta =
          shelly-manager.meta
          // {
            description = "REST API for Shelly Manager";
            longDescription = ''
              A Litestar-based REST API, served with uvicorn, for discovering and
              managing Shelly IoT devices locally without the Shelly Cloud. It is
              the backend used by the Shelly Manager web interface and also allows
              scheduled backups via APScheduler.
            '';
            mainProgram = "shelly-manager-api";
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
        meta =
          shelly-manager.meta
          // {
            description = "Command-line interface for Shelly Manager";
            longDescription = ''
              A command line tool, built with click and rich, for scanning for
              Shelly IoT devices, checking status, updating firmware, and managing
              device configuration locally without the Shelly Cloud.
            '';
            mainProgram = "shelly-manager";
          };
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
        meta =
          shelly-manager.meta
          // {
            description = "Core business logic for Shelly Manager";
            longDescription = ''
              The shared library behind Shelly Manager's API and CLI: device
              discovery (mDNS and network scanning), Gen1 and Gen2 Shelly device
              communication, firmware, configuration and encrypted backup
              management, and persistence.
            '';
          };
      })) {};

    shelly-manager-web = scope.callPackage ({
      buildNpmPackage,
      lib,
      writeText,
      shelly-manager,
      viteBaseApiUrl ? "http://localhost:8000",
      ...
    }:
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
        npmDepsHash = "sha256-dU27ZTD9+HHiQSsAlEM9zVVeSBHzJSNxSNnlG5ddZy4=";
        postInstall = ''
          ln -sfT ${configJs} $out/lib/node_modules/web/public/config.js
        '';
        meta =
          shelly-manager.meta
          // {
            description = "Web interface for Shelly Manager";
            longDescription = ''
              A React single-page web interface for Shelly Manager, providing a
              dashboard for device discovery, status monitoring, component
              controls, firmware updates and bulk operations on Shelly IoT devices.
              It talks to the Shelly Manager REST API.
            '';
          };
      })) {};
  })
