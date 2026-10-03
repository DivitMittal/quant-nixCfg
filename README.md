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
├── modules/home/      # graduated home-manager modules (programs.openalgo, programs.openbb)
├── pkgs/openalgo/     # OpenAlgo packaged via uv2nix (pyproject.toml + uv.lock)
├── pkgs/openbb/       # OpenBB Platform via uv2nix (local virtual uv project pinning openbb + extensions)
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

## OpenBB

[OpenBB-finance/OpenBB](https://github.com/OpenBB-finance/OpenBB) — investment
research platform: `obb.*` Python SDK, `openbb` CLI, `openbb-api` (FastAPI,
also the OpenBB Workspace backend) and `openbb-mcp` (MCP server), all from one
package.

**Packaging.** Upstream ships no application lockfile, so `pkgs/openbb/` is a
tiny *virtual* uv project (`pyproject.toml` + `uv.lock`) that pins
`openbb==5.0.0` and exposes each extension as an optional-dependency group.
`extensions` picks the groups: `openbb.override { extensions = [...]; }`.
OpenBB normally generates its `obb.*` interface into its own package dir on
first import; that's done at Nix build time instead (against a writable copy
of the `openbb` module, for exactly the chosen extensions) and the wrappers
set `OPENBB_AUTO_BUILD=false`, so nothing writes to the store at runtime.
Commercial providers (fmp, polygon, intrinio, …) haven't released for
`openbb-core>=2` yet and can't be added until they do. On x86_64-darwin
`cryptography` is constrained to `<49` (last release with an Intel macOS
wheel); everywhere else it resolves normally.

**Configuration.** OpenBB v5 reads a layered TOML config; the module renders
the user-global layer, `~/.openbb_platform/openbb.toml`, from typed options +
a freeform `settings` escape hatch, so everything — SDK preferences,
per-command default providers, HTTP proxy/CA, CLI REPL settings, API/MCP
launcher flags — is declared in Nix:

```nix
imports = [ inputs.quant-nixCfg.homeManagerModules.openbb ];

programs.openbb = {
  enable = true;
  package = inputs.quant-nixCfg.packages.${system}.openbb;
  extensions = [ "equity" "yfinance" "technical" "quantitative" "derivatives" ];

  preferences.output_type = "dataframe";            # obb.* returns DataFrames
  defaultProviders = {
    "equity.price.historical" = "yfinance";         # RELIANCE.NS, TCS.BO, …
    "equity.fundamental.income" = [ "sec" "yfinance" ];
  };
  http.proxy = "http://127.0.0.1:3128";              # every provider request

  environmentFile = "/run/agenix/openbb.env";        # FRED_API_KEY=…, OPENBB_API_PASSWORD=…

  settings = {                                       # anything else upstream supports
    timezone = "Asia/Kolkata";
    output-mode = "rich";
    system.api_settings.cors.allow_origins = [ "https://pro.openbb.co" ];
  };

  api.enable = true;                                 # :6900, systemd (Linux) / launchd (macOS)
  mcp = {
    enable = true;                                   # :8001, streamable-http
    allowedCategories = [ "equity" "economy" "news" ];
    toolDiscovery = true;
  };
};
```

`environmentFile` is linked (out of store) to `~/.openbb_platform/.env` —
the only dotenv OpenBB reads early enough for `*_API_KEY` provider
credentials to register. `OPENBB_ENV_FILE` is applied after the credentials
model is built, so it doesn't work for that.

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
