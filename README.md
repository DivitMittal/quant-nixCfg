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
├── modules/home/      # graduated home-manager modules (programs.openalgo, programs.qlib)
├── pkgs/openalgo/     # OpenAlgo packaged via uv2nix (pyproject.toml + uv.lock)
├── pkgs/qlib/         # Microsoft Qlib via uv2nix (local virtual uv project pinning pyqlib)
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

## Qlib

[microsoft/qlib](https://github.com/microsoft/qlib) — AI-oriented quant
research platform: data layer + expression engine (Alpha158/Alpha360
factors), model zoo, backtesting/portfolio analysis, MLflow-tracked
experiments, all driven by YAML workflows (`qrun`).

**Packaging.** `pkgs/qlib/` is a virtual uv project pinning `pyqlib==0.9.7`;
optional groups add model backends: `qlib.override { extras = [ "torch" "xgboost" ]; }` (`torch` is the CPU build from PyTorch's own index —
unavailable on Intel Macs, where PyTorch stopped shipping wheels —
`catboost`, `analysis`, `collectors`). Ships `qrun`, `qlib-python`,
`qlib-jupyter`, `qlib-mlflow` and `qlib-get-data` (the dataset downloader
upstream keeps outside the wheel). Packaging fixes worth knowing: LightGBM's
macOS wheel is re-pointed at nixpkgs' OpenMP (it otherwise looks for
Homebrew's `libomp`), `gym` is built from sdist, and the wrappers set
`MLFLOW_ALLOW_FILE_STORE=true` — current MLflow refuses the `file:` store
Qlib's recorders depend on unless opted in.

**Configuration.** Datasets, workflows and experiment tracking are all
declared; each workflow is rendered to `~/.config/qlib/workflows/<name>.yaml`
with `qlib_init` (data path, region, MLflow URI, cache dir) filled in, and
can run on a schedule:

```nix
imports = [ inputs.quant-nixCfg.homeManagerModules.qlib ];

programs.qlib = let
  handler = {
    start_time = "2008-01-01"; end_time = "2020-08-01";
    fit_start_time = "2008-01-01"; fit_end_time = "2014-12-31";
    instruments = "csi300";
  };
  portAnalysis = {
    strategy = { class = "TopkDropoutStrategy"; module_path = "qlib.contrib.strategy";
                 kwargs = { signal = "<PRED>"; topk = 50; n_drop = 5; }; };
    backtest = { start_time = "2017-01-01"; end_time = "2020-08-01"; account = 100000000;
                 benchmark = "SH000300";
                 exchange_kwargs = { limit_threshold = 0.095; deal_price = "close";
                                     open_cost = 0.0005; close_cost = 0.0015; min_cost = 5; }; };
  };
in {
  enable = true;
  package = inputs.quant-nixCfg.packages.${system}.qlib;
  extras = [ "xgboost" ];

  datasets = {
    cn_data.update = "weekly";                       # systemd timer / launchd calendar
    us_data.region = "us";
  };
  mlflow.ui.enable = true;                           # http://127.0.0.1:5000
  pythonPath = [ ./qlib-models ];                    # custom models/handlers via module_path

  workflows.lgb-alpha158 = {                         # upstream's LightGBM/Alpha158 benchmark
    schedule = "weekly";
    settings = {
      port_analysis_config = portAnalysis;
      task = {
        model = { class = "LGBModel"; module_path = "qlib.contrib.model.gbdt";
                  kwargs = { loss = "mse"; learning_rate = 0.2; num_leaves = 210; max_depth = 8;
                             colsample_bytree = 0.8879; subsample = 0.8789;
                             lambda_l1 = 205.6999; lambda_l2 = 580.9768; num_threads = 8; }; };
        dataset = { class = "DatasetH"; module_path = "qlib.data.dataset";
                    kwargs = {
                      handler = { class = "Alpha158"; module_path = "qlib.contrib.data.handler"; kwargs = handler; };
                      segments = { train = [ "2008-01-01" "2014-12-31" ]; valid = [ "2015-01-01" "2016-12-31" ];
                                   test = [ "2017-01-01" "2020-08-01" ]; };
                    }; };
        record = [
          { class = "SignalRecord"; module_path = "qlib.workflow.record_temp"; kwargs = { model = "<MODEL>"; dataset = "<DATASET>"; }; }
          { class = "SigAnaRecord"; module_path = "qlib.workflow.record_temp"; kwargs = { ana_long_short = false; ann_scaler = 252; }; }
          { class = "PortAnaRecord"; module_path = "qlib.workflow.record_temp"; kwargs.config = portAnalysis; }
        ];
      };
    };
  };
};
```

YAML anchors in upstream's benchmark configs become plain `let` bindings.
Unscheduled jobs are still installed: `systemctl --user start qlib-workflow-<name>` (Linux) or `launchctl kickstart gui/$UID/local.qlib-workflow-<name>`
(macOS), or just `qrun ~/.config/qlib/workflows/<name>.yaml`. Interactive
shells get `QLIB_PROVIDER_URI`/`QLIB_MLFLOW_URI`, so a bare `qlib.init()` in
`qlib-python`/`qlib-jupyter` uses the same data and experiment store.

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
