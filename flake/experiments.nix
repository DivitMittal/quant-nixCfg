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
    };
  };
}
