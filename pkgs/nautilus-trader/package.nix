## NautilusTrader (github.com/nautechsystems/nautilus_trader) — Rust-native,
## event-driven trading engine with a Python (Cython/pyo3) API; the same
## strategy code runs in backtest and live. Packaged via uv2nix from the
## sibling virtual uv project (pyproject.toml + uv.lock) pinning
## nautilus_trader==1.231.0, one optional-dependency group per upstream
## extra:
##   nautilus-trader.override { extras = ["ib"]; }
##
## Platforms: x86_64/aarch64-linux and aarch64-darwin only. Upstream ships
## no macOS x86_64 wheel and the source build (Rust workspace + Cython) is
## out of scope; uv.lock is resolved for those environments only.
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

  python = pkgs.python312;

  pythonSet =
    (pkgs.callPackage pyproject-nix.build.packages {inherit python;}).overrideScope
    (lib.composeManyExtensions [
      pyproject-build-systems.overlays.default
      overlay
    ]);

  venv = pythonSet.mkVirtualEnv "nautilus-trader-env" {nautilus-trader-nix = extras;};
in
  assert lib.assertMsg (lib.all (e: lib.elem e availableExtras) extras)
  "nautilus-trader: unknown extra(s) ${toString (lib.subtractLists availableExtras extras)}; available: ${toString availableExtras}";
    pkgs.stdenvNoCC.mkDerivation {
      pname = "nautilus-trader";
      inherit version;

      dontUnpack = true;
      nativeBuildInputs = [pkgs.makeWrapper];

      ## nautilus-node: run a live TradingNode from a JSON config (what the
      ## home-manager module's services exec). nautilus-python: the venv's
      ## interpreter for backtests/notebooks without shadowing `python`.
      installPhase = ''
        runHook preInstall

        mkdir -p $out/bin $out/libexec
        cp ${./nautilus-node.py} $out/libexec/nautilus-node.py
        makeWrapper ${venv}/bin/python $out/bin/nautilus-node \
          --add-flags $out/libexec/nautilus-node.py
        makeWrapper ${venv}/bin/python $out/bin/nautilus-python

        runHook postInstall
      '';

      doInstallCheck = true;
      installCheckPhase = ''
        $out/bin/nautilus-python -c "import nautilus_trader, nautilus_trader.live.node; print(nautilus_trader.__version__)"
      '';

      passthru = {
        inherit venv availableExtras extras;
      };

      meta = {
        description = "High-performance algorithmic trading platform and event-driven backtester";
        homepage = "https://github.com/nautechsystems/nautilus_trader";
        license = lib.licenses.lgpl3Plus;
        maintainers = [];
        ## pkgs.lib, not module-arg lib — see the note in ../openalgo/package.nix.
        platforms = ["x86_64-linux" "aarch64-linux" "aarch64-darwin"];
        mainProgram = "nautilus-node";
      };
    }
