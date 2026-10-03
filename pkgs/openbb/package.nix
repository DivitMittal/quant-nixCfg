## OpenBB Platform (github.com/OpenBB-finance/OpenBB) — Python data
## platform, `obb.*` SDK + `openbb` CLI + `openbb-api` (FastAPI) +
## `openbb-mcp` (MCP server). Upstream ships no app lockfile, so the
## sibling pyproject.toml/uv.lock here is a virtual uv project pinning
## `openbb==5.0.0` with one optional-dependency group per extension;
## uv2nix turns that into the Nix package set.
##
## `extensions` selects which of those groups land in the venv:
##   openbb.override { extensions = ["equity" "yfinance" "technical"]; }
## (or programs.openbb.extensions in the home-manager module).
{
  lib,
  pkgs,
  inputs,
  extensions ? [],
}: let
  inherit (inputs) uv2nix pyproject-nix pyproject-build-systems;

  workspace = uv2nix.lib.workspace.loadWorkspace {workspaceRoot = ./.;};
  pyprojectToml = lib.importTOML ./pyproject.toml;
  availableExtensions = lib.attrNames pyprojectToml.project.optional-dependencies;

  overlay = workspace.mkPyprojectOverlay {
    sourcePreference = "wheel";
  };

  python = pkgs.python312;

  pythonSet =
    (pkgs.callPackage pyproject-nix.build.packages {inherit python;}).overrideScope
    (lib.composeManyExtensions [
      pyproject-build-systems.overlays.default
      overlay
    ]);

  venv = pythonSet.mkVirtualEnv "openbb-env" {openbb-nix = extensions;};

  ## OpenBB generates its `obb.*` Python interface (openbb/package/*.py +
  ## openbb/assets/extension_map.json) from whatever extensions are
  ## installed, normally on first import, writing into its own package dir
  ## — which lives in openbb-core's read-only store path. Do that build
  ## here instead, against a writable copy of just the `openbb` module, for
  ## exactly the selected extension set. The wrappers below put this copy
  ## first on PYTHONPATH and turn auto-build off.
  openbbStatic =
    pkgs.runCommand "openbb-static-${version}" {
      nativeBuildInputs = [venv];
    } ''
      mkdir -p $out
      cp -rL ${venv}/${python.sitePackages}/openbb $out/openbb
      chmod -R u+w $out/openbb
      rm -rf $out/openbb/package/*.py $out/openbb/package/__pycache__

      export HOME=$TMPDIR OPENBB_AUTO_BUILD=false PYTHONPATH=$out
      # lint=True is load-bearing: the generator emits imports of runtime-only
      # OBBject_* models and relies on `ruff --fix` to strip them.
      python -c "import openbb; openbb.build(lint=True)"
      # namespaces import lazily — touch each so a broken generated module
      # fails the build rather than the first `obb.<ns>` call
      python -c "from openbb import obb; [getattr(obb, n) for n in dir(obb) if not n.startswith('_')]"
      python -m compileall -q $out/openbb
    '';

  version = pyprojectToml.project.version;
in
  assert lib.assertMsg (lib.all (e: lib.elem e availableExtensions) extensions)
  "openbb: unknown extension(s) ${toString (lib.subtractLists availableExtensions extensions)}; available: ${toString availableExtensions}";
    pkgs.stdenvNoCC.mkDerivation {
      pname = "openbb";
      inherit version;

      dontUnpack = true;
      nativeBuildInputs = [pkgs.makeWrapper];

      ## openbb / openbb-api / openbb-mcp / openbb-sec, plus python & ipython
      ## as openbb-python / openbb-ipython so `from openbb import obb` works
      ## in a REPL without shadowing the system python on PATH.
      installPhase = ''
        runHook preInstall

        mkdir -p $out/bin
        wrap() {
          makeWrapper ${venv}/bin/$1 $out/bin/$2 \
            --prefix PYTHONPATH : ${openbbStatic} \
            --set OPENBB_AUTO_BUILD false
        }
        for bin in openbb openbb-api openbb-mcp openbb-sec; do
          wrap $bin $bin
        done
        wrap python openbb-python
        wrap ipython openbb-ipython

        runHook postInstall
      '';

      passthru = {
        inherit venv openbbStatic availableExtensions extensions;
      };

      meta = {
        description = "OpenBB Platform: open-source investment research SDK, CLI, REST API and MCP server";
        homepage = "https://github.com/OpenBB-finance/OpenBB";
        license = lib.licenses.agpl3Only;
        maintainers = [];
        ## pkgs.lib, not module-arg lib — see the note in ../openalgo/package.nix.
        platforms = pkgs.lib.platforms.unix;
        mainProgram = "openbb";
      };
    }
