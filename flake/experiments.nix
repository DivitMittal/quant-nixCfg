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
      nautilus-trader = {
        devshell = {
          name = "nautilus-trader-experiment";
          motd = ''
            {202}nautilus_trader experiment shell{reset}

            git clone https://github.com/nautechsystems/nautilus_trader experiments/nautilus-trader/src
            cd experiments/nautilus-trader/src
            uv pip install nautilus_trader   # prebuilt wheel, if one exists for this platform
            # otherwise (per upstream README): rustup toolchain is on PATH here, then `make build`
          '';
          packages = pkgs.lib.attrsets.attrValues {
            inherit
              (pkgs)
              python312
              uv
              cargo
              rustc
              clang
              pkg-config
              openssl
              ;
          };
        };
      };

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

      openbb = {
        devshell = {
          name = "openbb-experiment";
          motd = ''
            {202}OpenBB Platform experiment shell{reset}

            uv venv --python 3.12 experiments/openbb/.venv && source experiments/openbb/.venv/bin/activate
            uv pip install openbb                         # core + default (mostly macro/gov) providers
            uv pip install openbb-equity openbb-yfinance  # v5 no longer bundles equity/yfinance
            uv pip install openbb-cli                     # optional: `openbb` terminal-style CLI
            python -c "from openbb import obb; print(obb.equity.price.historical('RELIANCE.NS', provider='yfinance').to_df().tail())"
            # source checkout instead: git clone https://github.com/OpenBB-finance/OpenBB experiments/openbb/src
          '';
          ## cargo/rustc/openssl: `cryptography` (pulled in via openbb-devtools)
          ## has no x86_64-darwin wheel and builds from source there
          packages = pkgs.lib.attrsets.attrValues {
            inherit
              (pkgs)
              python312
              uv
              cargo
              rustc
              pkg-config
              openssl
              ;
          };
        };
        env = [
          {
            name = "PKG_CONFIG_PATH";
            value = "${pkgs.openssl.dev}/lib/pkgconfig";
          }
        ];
      };
    };
  };
}
