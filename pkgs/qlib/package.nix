## Microsoft Qlib (github.com/microsoft/qlib) — AI-oriented quant research
## platform: data layer + expression engine, model zoo (LightGBM, linear,
## and with the `torch` extra the deep models), backtest/portfolio analysis,
## and MLflow-tracked experiments, driven by YAML workflows (`qrun`).
## Packaged via uv2nix from the sibling virtual uv project pinning
## pyqlib==0.9.7; optional groups add model backends:
##   qlib.override { extras = ["torch" "xgboost"]; }
{
  lib,
  pkgs,
  inputs,
  extras ? [],
}: let
  inherit (inputs) uv2nix pyproject-nix pyproject-build-systems;

  workspace = uv2nix.lib.workspace.loadWorkspace {workspaceRoot = ./.;};
  pyprojectToml = lib.importTOML ./pyproject.toml;
  availableExtras = lib.attrNames pyprojectToml.project.optional-dependencies;
  inherit (pyprojectToml.project) version;

  overlay = workspace.mkPyprojectOverlay {
    sourcePreference = "wheel";
  };

  pyprojectOverrides = final: prev:
    {
      ## Source-only dep: its build backend isn't recorded in uv.lock.
      gym = prev.gym.overrideAttrs (old: {
        nativeBuildInputs = (old.nativeBuildInputs or []) ++ final.resolveBuildSystem {setuptools = [];};
      });
    }
    // lib.optionalAttrs pkgs.stdenv.isDarwin {
      ## LightGBM's macOS wheel links @rpath/libomp.dylib and only searches
      ## Homebrew/MacPorts prefixes; point it at nixpkgs' OpenMP instead.
      lightgbm = prev.lightgbm.overrideAttrs (old: {
        postFixup =
          (old.postFixup or "")
          + ''
            for lib in $out/${python.sitePackages}/lightgbm/lib/*.dylib; do
              ${pkgs.darwin.cctools}/bin/install_name_tool -add_rpath ${lib.getLib pkgs.llvmPackages.openmp}/lib "$lib"
            done
          '';
      });
    };

  python = pkgs.python312;

  pythonSet =
    (pkgs.callPackage pyproject-nix.build.packages {inherit python;}).overrideScope
    (lib.composeManyExtensions [
      pyproject-build-systems.overlays.default
      overlay
      pyprojectOverrides
    ]);

  venv = pythonSet.mkVirtualEnv "qlib-env" {qlib-nix = extras;};
in
  assert lib.assertMsg (lib.all (e: lib.elem e availableExtras) extras)
  "qlib: unknown extra(s) ${toString (lib.subtractLists availableExtras extras)}; available: ${toString availableExtras}";
    pkgs.stdenvNoCC.mkDerivation {
      pname = "qlib";
      inherit version;

      dontUnpack = true;
      nativeBuildInputs = [pkgs.makeWrapper];

      ## Prefixed so none of these shadow a system python/jupyter/mlflow.
      ## MLFLOW_ALLOW_FILE_STORE: MLflow >= 3.x refuses the `file:` tracking
      ## store unless opted in, but Qlib's recorders are built around it
      ## (artifacts resolved as local dirs). Overridable per environment.
      installPhase = ''
        runHook preInstall

        mkdir -p $out/bin $out/libexec
        cp ${./qlib-get-data.py} $out/libexec/qlib-get-data.py

        wrap() {
          makeWrapper ${venv}/bin/$1 $out/bin/$2 \
            --set-default MLFLOW_ALLOW_FILE_STORE true \
            "''${@:3}"
        }
        wrap qrun qrun
        wrap python qlib-python
        wrap python qlib-get-data --add-flags $out/libexec/qlib-get-data.py
        wrap mlflow qlib-mlflow
        wrap jupyter qlib-jupyter

        runHook postInstall
      '';

      doInstallCheck = true;
      installCheckPhase = ''
        $out/bin/qlib-python -c "import qlib, lightgbm, qlib.contrib.model.gbdt; print(qlib.__version__)"
      '';

      passthru = {
        inherit venv availableExtras extras;
      };

      meta = {
        description = "AI-oriented quantitative investment research platform";
        homepage = "https://github.com/microsoft/qlib";
        license = lib.licenses.mit;
        maintainers = [];
        ## pkgs.lib, not module-arg lib — see the note in ../openalgo/package.nix.
        platforms = pkgs.lib.platforms.unix;
        mainProgram = "qrun";
      };
    }
