## programs.qlib — Microsoft Qlib research setup as code.
##
## Qlib's moving parts, each declared here:
##
##   datasets.<name>   prebuilt market data (qlib-get-data) under dataDir,
##                     optionally refreshed on a schedule
##   workflows.<name>  `qrun` YAML workflows (dataset handler, model, backtest
##                     + analysis records), rendered to
##                     ~/.config/qlib/workflows/<name>.yaml with `qlib_init`
##                     (data, region, MLflow, cache) filled in, optionally run
##                     on a schedule as a user service
##   mlflow            where experiment runs/recorders are tracked, plus an
##                     optional `mlflow ui` service to browse them
##
## Interactive sessions get QLIB_PROVIDER_URI / QLIB_MLFLOW_URI exported, so
## a bare `qlib.init()` in `qlib-python`/`qlib-jupyter` picks up the same
## defaults the workflows use.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkIf mkOption mkEnableOption types literalExpression;
  cfg = config.programs.qlib;

  yamlFormat = pkgs.formats.yaml {};

  availableExtras =
    lib.attrNames
    (lib.importTOML ../../pkgs/qlib/pyproject.toml).project.optional-dependencies;

  finalPackage =
    if cfg.package == null
    then null
    else cfg.package.override {inherit (cfg) extras;};

  stateDir = "${config.xdg.stateHome}/qlib";
  datasetDir = name: "${cfg.dataDir}/${name}";

  scheduleType = types.nullOr (types.enum ["daily" "weekly" "monthly"]);

  ## systemd OnCalendar shorthands ↔ launchd StartCalendarInterval
  launchdCalendar = {
    daily = {
      Hour = 6;
      Minute = 0;
    };
    weekly = {
      Weekday = 6;
      Hour = 6;
      Minute = 0;
    };
    monthly = {
      Day = 1;
      Hour = 6;
      Minute = 0;
    };
  };

  datasetModule = types.submodule ({name, ...}: {
    options = {
      region = mkOption {
        type = types.enum ["cn" "us"];
        default = "cn";
        description = "Market: `cn` (CSI300/CSI500 universe) or `us` (S&P 500 / NASDAQ 100).";
      };

      interval = mkOption {
        type = types.enum ["1d" "1min"];
        default = "1d";
        description = "Bar interval of the dataset.";
      };

      variant = mkOption {
        type = types.enum ["qlib_data" "qlib_data_simple"];
        default = "qlib_data";
        description = "`qlib_data_simple` is a much smaller cut, good enough to try workflows.";
      };

      update = mkOption {
        type = scheduleType;
        default = null;
        example = "weekly";
        description = "Re-download on this schedule (user timer / launchd agent). `null`: only `qlib-get-data` by hand.";
      };

      path = mkOption {
        type = types.str;
        readOnly = true;
        default = datasetDir name;
        defaultText = literalExpression ''"''${dataDir}/<name>"'';
        description = "Where this dataset lives (read-only; for referencing elsewhere).";
      };
    };
  });

  workflowModule = types.submodule ({name, ...}: {
    options = {
      dataset = mkOption {
        type = types.str;
        default = cfg.defaultDataset;
        defaultText = literalExpression "config.programs.qlib.defaultDataset";
        description = "Name of a `datasets.*` entry to run against.";
      };

      experimentName = mkOption {
        type = types.str;
        default = name;
        description = "MLflow experiment the run is recorded under.";
      };

      schedule = mkOption {
        type = scheduleType;
        default = null;
        example = "weekly";
        description = "Run on this schedule. `null`: render the YAML and a manually-startable service only.";
      };

      qlibInit = mkOption {
        inherit (yamlFormat) type;
        default = {};
        example = literalExpression ''
          {
            expression_cache = "DiskExpressionCache";
            dataset_cache = "DiskDatasetCache";
            redis_host = "127.0.0.1";
            kernels = 8;
          }
        '';
        description = "Extra `qlib.init()` kwargs, merged over the generated provider/region/MLflow/cache ones.";
      };

      settings = mkOption {
        inherit (yamlFormat) type;
        example = literalExpression ''
          {
            market = "csi300";
            benchmark = "SH000300";
            task = {
              model = {
                class = "LGBModel";
                module_path = "qlib.contrib.model.gbdt";
                kwargs = { loss = "mse"; learning_rate = 0.2; num_leaves = 210; num_threads = 8; };
              };
              dataset = { class = "DatasetH"; module_path = "qlib.data.dataset"; kwargs = { … }; };
              record = [ { class = "SignalRecord"; module_path = "qlib.workflow.record_temp"; } … ];
            };
          }
        '';
        description = ''
          The workflow itself — everything `qrun` reads besides
          `qlib_init`: `task` (model, dataset/handler, records),
          `port_analysis_config`, and any top-level anchors. Same schema as
          upstream's examples/benchmarks/*/workflow_config_*.yaml.
        '';
      };
    };
  });

  qlibInitFor = w: let
    dataset = cfg.datasets.${w.dataset};
  in
    lib.recursiveUpdate {
      provider_uri = dataset.path;
      inherit (dataset) region;
      local_cache_path = cfg.cacheDir;
      exp_manager = {
        class = "MLflowExpManager";
        module_path = "qlib.workflow.expm";
        kwargs = {
          uri = cfg.mlflow.trackingUri;
          default_exp_name = "Experiment";
        };
      };
    }
    w.qlibInit;

  renderWorkflow = name: w:
    yamlFormat.generate "qlib-workflow-${name}.yaml" (lib.foldl' lib.recursiveUpdate {} [
      {
        qlib_init = qlibInitFor w;
        experiment_name = w.experimentName;
      }
      (lib.optionalAttrs (cfg.pythonPath != []) {
        sys.path = map (p: "${p}") cfg.pythonPath; # interpolation copies path literals into the store
      })
      w.settings
    ]);

  workflowFiles = lib.mapAttrs renderWorkflow cfg.workflows;

  getDataCommand = name: d: [
    "${finalPackage}/bin/qlib-get-data"
    "qlib_data"
    "--name"
    d.variant
    "--target_dir"
    (datasetDir name)
    "--region"
    d.region
    "--interval"
    d.interval
  ];

  ## Every job is a oneshot: a systemd service (+ timer when scheduled) on
  ## Linux, a launchd agent on macOS (calendar-triggered when scheduled,
  ## otherwise loaded but only run via `launchctl kickstart`).
  jobs =
    lib.mapAttrs' (name: d:
      lib.nameValuePair "qlib-data-${name}" {
        description = "Qlib dataset ${name} (${d.variant} ${d.region} ${d.interval})";
        command = getDataCommand name d;
        schedule = d.update;
      })
    cfg.datasets
    // lib.mapAttrs' (name: w:
      lib.nameValuePair "qlib-workflow-${name}" {
        description = "Qlib workflow ${name}";
        command = ["${finalPackage}/bin/qrun" "${workflowFiles.${name}}"];
        inherit (w) schedule;
      })
    cfg.workflows;
in {
  options.programs.qlib = {
    enable = mkEnableOption "Microsoft Qlib (`qrun`, `qlib-python`, `qlib-jupyter`, `qlib-get-data`, `qlib-mlflow`)";

    package = lib.mkPackageOption pkgs "qlib" {nullable = true;};

    extras = mkOption {
      type = types.listOf (types.enum availableExtras);
      default = [];
      example = ["torch" "xgboost"];
      description = ''
        Optional backends baked into the package: `torch` (deep models,
        CPU build; unavailable on Intel Macs), `xgboost`, `catboost`,
        `analysis` (report graphs), `collectors` (Yahoo/BaoStock data
        collectors). LightGBM, MLflow, cvxpy and Jupyter are always there.
      '';
    };

    dataDir = mkOption {
      type = types.str;
      default = "${config.xdg.dataHome}/qlib";
      defaultText = literalExpression ''"''${config.xdg.dataHome}/qlib"'';
      description = "Root for `datasets.*` (replaces upstream's `~/.qlib/qlib_data`).";
    };

    cacheDir = mkOption {
      type = types.str;
      default = "${config.xdg.cacheHome}/qlib";
      defaultText = literalExpression ''"''${config.xdg.cacheHome}/qlib"'';
      description = "Expression/dataset cache (`local_cache_path`).";
    };

    datasets = mkOption {
      type = types.attrsOf datasetModule;
      default = {
        cn_data = {};
      };
      example = literalExpression ''
        {
          cn_data = { update = "weekly"; };
          us_data = { region = "us"; };
          cn_data_1min = { interval = "1min"; };
        }
      '';
      description = "Prebuilt Qlib datasets, each downloaded to `<dataDir>/<name>`.";
    };

    defaultDataset = mkOption {
      type = types.str;
      default = "cn_data";
      description = "Dataset exported as QLIB_PROVIDER_URI and used by workflows that don't pick one.";
    };

    pythonPath = mkOption {
      type = types.listOf (types.either types.path types.package);
      default = [];
      example = literalExpression "[ ./qlib-models ]";
      description = ''
        Directories with your own models/handlers/strategies, added to every
        workflow's `sys.path` (reference them via `module_path`).
      '';
    };

    mlflow = {
      trackingUri = mkOption {
        type = types.str;
        default = "file:${stateDir}/mlruns";
        defaultText = literalExpression ''"file:''${config.xdg.stateHome}/qlib/mlruns"'';
        example = "http://mlflow.lan:5000";
        description = ''
          MLflow tracking URI for all experiments (instead of upstream's
          `./mlruns` relative to wherever `qrun` happened to run).
        '';
      };

      ui = {
        enable = mkEnableOption "`mlflow ui` as a user service for browsing runs (local `file:` tracking only)";

        host = mkOption {
          type = types.str;
          default = "127.0.0.1";
          description = "Address the MLflow UI binds to.";
        };

        port = mkOption {
          type = types.port;
          default = 5000;
          description = "Port the MLflow UI listens on.";
        };
      };
    };

    workflows = mkOption {
      type = types.attrsOf workflowModule;
      default = {};
      description = "`qrun` workflows; see the README for a full LightGBM/Alpha158 example.";
    };
  };

  config = mkIf cfg.enable {
    assertions =
      [
        {
          assertion = lib.hasAttr cfg.defaultDataset cfg.datasets;
          message = "programs.qlib.defaultDataset = \"${cfg.defaultDataset}\" is not one of programs.qlib.datasets (${toString (lib.attrNames cfg.datasets)}).";
        }
        {
          assertion = cfg.package != null || (cfg.workflows == {} && !cfg.mlflow.ui.enable);
          message = "programs.qlib workflows/mlflow.ui require programs.qlib.package to be non-null.";
        }
        {
          assertion = !cfg.mlflow.ui.enable || lib.hasPrefix "file:" cfg.mlflow.trackingUri;
          message = "programs.qlib.mlflow.ui serves a local `file:` store; with a remote trackingUri, use that server's UI.";
        }
      ]
      ++ lib.mapAttrsToList (name: w: {
        assertion = lib.hasAttr w.dataset cfg.datasets;
        message = "programs.qlib.workflows.${name}.dataset = \"${w.dataset}\" is not one of programs.qlib.datasets.";
      })
      cfg.workflows;

    home = {
      packages = mkIf (finalPackage != null) [finalPackage];

      sessionVariables = {
        QLIB_PROVIDER_URI = cfg.datasets.${cfg.defaultDataset}.path;
        QLIB_MLFLOW_URI = cfg.mlflow.trackingUri;
      };

      activation.qlibDirectories = lib.hm.dag.entryAfter ["writeBoundary"] ''
        ${pkgs.coreutils}/bin/mkdir -p \
          ${lib.escapeShellArg cfg.dataDir} \
          ${lib.escapeShellArg cfg.cacheDir} \
          ${lib.escapeShellArg "${stateDir}/mlruns"}
      '';
    };

    xdg.configFile =
      lib.mapAttrs' (name: file: lib.nameValuePair "qlib/workflows/${name}.yaml" {source = file;})
      workflowFiles;

    systemd.user = mkIf pkgs.stdenv.isLinux {
      services =
        lib.mapAttrs (_: job: {
          Unit.Description = job.description;
          Service = {
            Type = "oneshot";
            ExecStart = lib.escapeShellArgs job.command;
            WorkingDirectory = stateDir;
            Environment = ["PYTHONUNBUFFERED=1"];
          };
        })
        jobs
        // lib.optionalAttrs cfg.mlflow.ui.enable {
          qlib-mlflow-ui = {
            Unit.Description = "MLflow UI for Qlib experiments";
            Service = {
              ExecStart = lib.escapeShellArgs [
                "${finalPackage}/bin/qlib-mlflow"
                "ui"
                "--backend-store-uri"
                cfg.mlflow.trackingUri
                "--host"
                cfg.mlflow.ui.host
                "--port"
                (toString cfg.mlflow.ui.port)
              ];
              Restart = "on-failure";
            };
            Install.WantedBy = ["default.target"];
          };
        };

      timers =
        lib.mapAttrs (name: job: {
          Unit.Description = "Schedule for ${name}";
          Timer = {
            OnCalendar = job.schedule;
            Persistent = true;
            RandomizedDelaySec = "15m";
          };
          Install.WantedBy = ["timers.target"];
        })
        (lib.filterAttrs (_: job: job.schedule != null) jobs);
    };

    launchd.agents = mkIf pkgs.stdenv.isDarwin (
      lib.mapAttrs (name: job: {
        enable = true;
        config =
          {
            Label = "local.${name}";
            ProgramArguments = job.command;
            WorkingDirectory = stateDir;
            EnvironmentVariables.PYTHONUNBUFFERED = "1";
            StandardOutPath = "${stateDir}/${name}.log";
            StandardErrorPath = "${stateDir}/${name}.log";
          }
          // lib.optionalAttrs (job.schedule != null) {
            StartCalendarInterval = [launchdCalendar.${job.schedule}];
          };
      })
      jobs
      // lib.optionalAttrs cfg.mlflow.ui.enable {
        qlib-mlflow-ui = {
          enable = true;
          config = {
            Label = "local.qlib-mlflow-ui";
            ProgramArguments = [
              "${finalPackage}/bin/qlib-mlflow"
              "ui"
              "--backend-store-uri"
              cfg.mlflow.trackingUri
              "--host"
              cfg.mlflow.ui.host
              "--port"
              (toString cfg.mlflow.ui.port)
            ];
            RunAtLoad = true;
            KeepAlive.SuccessfulExit = false;
            StandardOutPath = "${stateDir}/mlflow-ui.log";
            StandardErrorPath = "${stateDir}/mlflow-ui.log";
          };
        };
      }
    );
  };
}
