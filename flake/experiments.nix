## Low-ceremony devShells for trying out popular (>500★) open-source trading
## and quant tools — see ../experiments/README.md. Each shell pins only the
## *system-level* toolchain the upstream project's own install docs call for
## (compilers, native libs); the app itself is a scratch `git clone` under
## experiments/<tool>/src (gitignored), driven by whatever the upstream
## project actually uses (uv/pip/cargo/qrun/...). Nothing here is packaged
## or deployed — that only happens for tools that graduate to ../pkgs +
## ../modules/home.
_: {
  perSystem = {pkgs, ...}: {
    devshells = {
      qlib = {
        devshell = {
          name = "qlib-experiment";
          motd = ''
            {202}Qlib experiment shell{reset}

            git clone https://github.com/microsoft/qlib experiments/qlib/src
            cd experiments/qlib/src
            uv pip install pyqlib   # or `uv pip install -e .` for an editable checkout
            qrun examples/benchmarks/LightGBM/workflow_config_lightgbm_Alpha158.yaml
          '';
          packages = pkgs.lib.attrsets.attrValues {
            inherit
              (pkgs)
              python312
              uv
              cmake
              pkg-config
              ;
          };
        };
      };
    };
  };
}
