# experiments/

Sandbox for trying popular (>500★) open-source equities/derivatives trading
and quant tools, globally — not just OpenAlgo/Indian-market-specific.

## Pattern

Each tool gets a `devShells.<tool>` in `../flake/experiments.nix` that pins
only the system-level toolchain its own install docs call for (compilers,
native libs like openssl/ta-lib/rust). Nothing is packaged or vendored:

```console
$ nix develop .#nautilus-trader
$ git clone https://github.com/nautechsystems/nautilus_trader experiments/nautilus-trader/src
$ cd experiments/nautilus-trader/src && uv pip install nautilus_trader
```

`experiments/<tool>/src` is gitignored — it's a scratch checkout, not
vendored source. Log what you tried and the verdict in `LOG.md`.

## Graduating a tool

If something earns a permanent spot (like OpenAlgo did), it moves out of
this low-ceremony pattern into `../pkgs/<tool>/package.nix` +
`../modules/home/<tool>.nix` — full Nix packaging, a real home-manager
service module, the works. That move is the signal a tool is no longer an
experiment.
