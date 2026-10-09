# quant-nixCfg

Experimental sandbox for trying popular (>500★) open-source equities/
derivatives trading and quant tools, global markets — plus the Nix
home-manager modules and packages for the ones that graduate to actual
long-term use from [OS-nixCfg](https://github.com/DivitMittal/OS-nixCfg).
Mirrors the shape of [ai-nixCfg](https://github.com/DivitMittal/ai-nixCfg)
(flake-parts, `import-tree`, `modules/home`, `pkgs/custom`-equivalent).

## Structure

```
./
├── experiments/       # low-ceremony devShells for trying tools — see experiments/README.md
├── flake/             # flake-parts modules: formatters.nix, checks.nix, devshells.nix, experiments.nix
├── modules/home/      # graduated home-manager modules (programs.openalgo, programs.nautilus-trader)
├── pkgs/openalgo/     # OpenAlgo packaged via uv2nix (pyproject.toml + uv.lock)
├── pkgs/nautilus-trader/ # NautilusTrader via uv2nix (local virtual uv project) + nautilus-node launcher
└── README.md
```

## OpenAlgo

[marketcalls/openalgo](https://github.com/marketcalls/openalgo) — Flask
backend + React 19 SPA, Python >= 3.12, managed upstream with `uv`. Packaged
here via [uv2nix](https://github.com/pyproject-nix/uv2nix) rather than a
hand-rolled `buildPythonApplication`, since the lockfile pins ~150 transitive
deps.

**Known caveat:** `cryptography==50.0.0`'s PyPI wheels don't cover macOS
x86_64 (only `macosx_11_0_arm64`); on an Intel Mac dev machine this forces a
from-source maturin/Rust build, which needs a `cargoDeps` vendor hash filled
in (`pkgs/openalgo/package.nix`, currently `lib.fakeHash` — replace with the
value `nix build` reports on hash mismatch). **This does not affect the real
deployment target**: the lock carries `manylinux_2_28`/`manylinux_2_34`/
`manylinux2014` x86_64 + aarch64 wheels for cryptography, so on x86_64-linux
or aarch64-linux (i.e. any NixOS host in OS-nixCfg) uv2nix resolves the
prebuilt wheel directly and never touches the sdist path. Verified via
`nix eval .#packages.x86_64-linux.openalgo.drvPath --impure`, which evaluates
cleanly; a full native Linux build still needs to run once on an actual
Linux builder to catch anything eval can't (other sdist-only deps in the
~150-package closure may need similar `pyprojectOverrides` treatment — none
surfaced before `cryptography` did on this Mac, but Linux may hit different
ones).

### openalgo-charts

[marketcalls/openalgo-charts](https://github.com/marketcalls/openalgo-charts)
is a dependency-free TypeScript **charting library** (\<50KB Brotli, built
with Rollup), not a standalone service — it's consumed by a frontend's build
step, not deployed on its own. No separate module/package for it here; if
OpenAlgo's own frontend build pulls it in as an npm dep, that's handled
inside the `openalgo` package build, not as independent infra.

## NautilusTrader

[nautechsystems/nautilus_trader](https://github.com/nautechsystems/nautilus_trader)
— Rust-native, event-driven trading engine with a Python API; the same
strategy code runs in backtests and live.

**Packaging.** `pkgs/nautilus-trader/` is a virtual uv project pinning
`nautilus_trader==1.231.0`; each upstream extra (`ib`, `betfair`,
`polymarket`, `docker`, `visualization`) is an optional group selected via
`nautilus-trader.override { extras = [...]; }`. The Rust-native adapters
(Binance, Bybit, OKX, Databento, dYdX, Hyperliquid, Kraken, BitMEX, Deribit,
Tardis, sandbox, …) are always in the base wheel. Ships `nautilus-node`
(runs a live node from a JSON `TradingNodeConfig`; also works around an
upstream 1.231.0 bug that breaks every JSON-configured exec client) and
`nautilus-python` (for backtests/notebooks).
**Platforms:** x86_64/aarch64-linux and aarch64-darwin — upstream publishes
no macOS x86_64 wheel, so there's no `packages.x86_64-darwin.nautilus-trader`.

**Configuration.** A live deployment is one `TradingNodeConfig` per node;
the module renders each `nodes.<name>` to
`~/.config/nautilus-trader/nodes/<name>.json` and runs it as a user service
(systemd on Linux, launchd on macOS):

```nix
imports = [ inputs.quant-nixCfg.homeManagerModules.nautilus-trader ];

programs.nautilus-trader = {
  enable = true;
  package = inputs.quant-nixCfg.packages.${system}.nautilus-trader;
  pythonPath = [ ./strategies ];                 # your strategy/actor modules, pinned per generation
  environmentFile = "/run/agenix/nautilus.env";  # BINANCE_API_KEY=…, BINANCE_API_SECRET=…

  nodes.paper = {
    environment = "sandbox";                     # live market data, simulated fills
    dataClients.BINANCE = {
      path = "nautilus_trader.adapters.binance:BinanceDataClientConfig";
      factory = "nautilus_trader.adapters.binance:BinanceLiveDataClientFactory";
      config = { account_type = "SPOT"; instrument_provider.load_ids = [ "BTCUSDT.BINANCE" ]; };
    };
    execClients.BINANCE = {
      path = "nautilus_trader.adapters.sandbox.config:SandboxExecutionClientConfig";
      factory = "nautilus_trader.adapters.sandbox.factory:SandboxLiveExecClientFactory";
      config = { venue = "BINANCE"; account_type = "CASH"; starting_balances = [ "10000 USDT" "1 BTC" ]; };
    };
    strategies = [{
      path = "my_strategies.ema:EMACross";
      configPath = "my_strategies.ema:EMACrossConfig";
      config = {
        instrument_id = "BTCUSDT.BINANCE";
        bar_type = "BTCUSDT.BINANCE-1-MINUTE-LAST-INTERNAL";
        trade_size = "0.001";
      };
    }];
    redis.enable = true;                         # cache + message bus survive restarts
    settings.risk_engine.max_order_submit_rate = "50/00:00:01";  # any TradingNodeConfig field
  };
};
```

Switching that node to real trading is `environment = "live"` plus the
venue's own exec client (`BinanceExecClientConfig` /
`BinanceLiveExecClientFactory`). `nautilus-node --check <config.json>`
parses and builds a node without running it.

## Deploying

```nix
# in a NixOS host's home-manager config
imports = [ inputs.quant-nixCfg.homeManagerModules.openalgo ];

programs.openalgo = {
  enable = true;
  package = inputs.quant-nixCfg.packages.${system}.openalgo;
  service.enable = true; # Linux systemd user service only
  environmentFiles = [ "%h/.config/openalgo/secrets.env" ]; # agenix/ragenix-managed
};
```

`environmentFiles` must supply `BROKER_API_KEY`, `BROKER_API_SECRET`,
`APP_KEY`, `API_KEY_PEPPER`, `FERNET_SALT` (see upstream `.sample.env`) —
never put these in `programs.openalgo.environment`, which lands in the
generated (world-readable) systemd unit in the Nix store.
