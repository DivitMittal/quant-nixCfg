## OpenAlgo (github.com/marketcalls/openalgo) — Flask backend + React 19 SPA,
## managed upstream with `uv` (pyproject.toml + uv.lock, Python >= 3.12).
## Packaged via uv2nix rather than hand-rolled buildPythonApplication: the
## upstream lockfile pins ~150 transitive deps (numpy, cryptography, duckdb,
## mcp, jupyter kernel bits, …), which is exactly what uv2nix exists to turn
## into a Nix package set without manually re-deriving each pin.
##
## First `nix build` will very likely need `pyprojectOverrides` entries below
## — sdist-only deps (anything without a wheel on PyPI) don't carry their
## build-system requirements (hatchling, setuptools-rust, maturin, …) in the
## lock, so uv2nix can't infer them and the build fails per-package until an
## override supplies `nativeBuildInputs`. This is standard/expected uv2nix
## friction, not a mistake in this file — iterate here.
{
  lib,
  pkgs,
  inputs,
  system,
}: let
  inherit (inputs) uv2nix pyproject-nix pyproject-build-systems;

  src = pkgs.fetchFromGitHub {
    owner = "marketcalls";
    repo = "openalgo";
    rev = "16bf8e7f80770065fc31e0d9b188805bb7bdc39b"; # main @ 2026-08-19
    hash = "sha256-m9txdUvS8XSsOTcPDEtxwDxoiYS0O/1nN6t49MActBo=";
  };

  workspace = uv2nix.lib.workspace.loadWorkspace {workspaceRoot = src;};

  ## uv2nix's workspace value has no top-level `version` — read it straight
  ## from pyproject.toml instead of guessing at the uv2nix API surface.
  pyprojectToml = lib.importTOML (src + "/pyproject.toml");

  overlay = workspace.mkPyprojectOverlay {
    sourcePreference = "wheel";
  };

  ## Per-package fixups for deps whose sdist doesn't declare its own build
  ## system in a way uv2nix can infer. Extend this as `nix build` surfaces
  ## missing-build-backend errors.
  ## NOTE (verified 2026-08-20): cryptography==50.0.0's uv.lock entry ships
  ## manylinux wheels (manylinux_2_28/2_34/2014 x86_64 + aarch64) but no
  ## macOS x86_64 wheel — only macosx_11_0_arm64. On x86_64-linux (the real
  ## deployment target: T2/L2/ASL1N are all NixOS) uv2nix resolves the
  ## manylinux wheel directly and never touches the maturin/Rust sdist build
  ## below. This override exists only so `nix build` also works untouched on
  ## an Intel Mac dev machine; drop it if targeting Apple Silicon or Linux
  ## only.
  pyprojectOverrides = final: prev:
    lib.optionalAttrs (system == "x86_64-darwin") {
      cryptography = prev.cryptography.overrideAttrs (old: {
        nativeBuildInputs =
          (old.nativeBuildInputs or [])
          ++ (final.resolveBuildSystem {maturin = [];})
          ++ [pkgs.rustPlatform.cargoSetupHook pkgs.rustPlatform.maturinBuildHook pkgs.cargo pkgs.rustc];
        cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
          inherit (old) src;
          name = "cryptography-${old.version}";
          sourceRoot = "cryptography-${old.version}/src/rust";
          hash = lib.fakeHash;
        };
        sourceRoot = "cryptography-${old.version}/src/rust";
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

  venv = pythonSet.mkVirtualEnv "openalgo-env" workspace.deps.default;
in
  pkgs.stdenvNoCC.mkDerivation {
    pname = "openalgo";
    version = pyprojectToml.project.version;
    inherit src;

    dontBuild = true;
    dontConfigure = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin $out/share/openalgo
      cp -r . $out/share/openalgo

      # No --run "cd ...": OpenAlgo resolves its sqlite DATABASE_URL paths
      # relative to the process CWD (see .sample.env upstream), which must
      # stay whatever the caller/systemd WorkingDirectory sets it to.
      makeWrapper ${venv}/bin/python $out/bin/openalgo \
        --add-flags "$out/share/openalgo/app.py"

      runHook postInstall
    '';

    nativeBuildInputs = [pkgs.makeWrapper];

    meta = {
      description = "Self-hosted open-source algo trading and options analytics platform for Indian brokers";
      homepage = "https://github.com/marketcalls/openalgo";
      license = lib.licenses.agpl3Only;
      maintainers = [];
      ## Use pkgs.lib here, not the module-arg `lib`: on x86_64-darwin, pkgs
      ## is pinned to nixpkgs-2605 (see flake.nix's isX86Darwin swap) while
      ## the module-arg `lib` still resolves to nixpkgs-unstable's lib, whose
      ## platform lists already dropped x86_64-darwin. Mixing the two made
      ## meta.platforms disagree with pkgs.stdenv.hostPlatform and made the
      ## build refuse to evaluate on this very machine.
      platforms = pkgs.lib.platforms.unix;
      mainProgram = "openalgo";
    };
  }
