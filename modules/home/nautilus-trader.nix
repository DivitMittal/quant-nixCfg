## programs.nautilus-trader — NautilusTrader live nodes as code.
##
## A NautilusTrader live deployment is one `TradingNodeConfig` per node:
## engines, cache/message-bus backing (Redis), logging, data + execution
## clients (venue adapters) and the strategies/actors to load — all
## importable by `module:Class` path. Each `nodes.<name>` here renders that
## config to JSON (~/.config/nautilus-trader/nodes/<name>.json) and, unless
## disabled, runs it as a user service via the package's `nautilus-node`.
##
## Strategy/actor code is yours: put it on `pythonPath` (a source dir or a
## Python package derivation) and reference it by import path. Venue
## credentials (BINANCE_API_KEY, BYBIT_API_SECRET, DATABENTO_API_KEY, …)
## are read from the environment by the adapters — supply them through
## `environmentFile`, never through the rendered JSON (world-readable store).
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkIf mkOption mkEnableOption types literalExpression;
  cfg = config.programs.nautilus-trader;

  jsonFormat = pkgs.formats.json {};

  availableExtras =
    lib.attrNames
    (lib.importTOML ../../pkgs/nautilus-trader/pyproject.toml).project.optional-dependencies;

  finalPackage =
    if cfg.package == null
    then null
    else cfg.package.override {inherit (cfg) extras;};

  stateDir = "${config.xdg.stateHome}/nautilus-trader";

  ## "${p}" (not toString) so path literals are copied into the store.
  pythonPathString = lib.concatMapStringsSep ":" (p: "${p}") cfg.pythonPath;

  importableOptions = kind: {
    path = mkOption {
      type = types.strMatching ".+:.+";
      example = "my_strategies.ema:EMACross";
      description = "Import path of the ${kind} class, `module.path:ClassName`.";
    };

    configPath = mkOption {
      type = types.strMatching ".+:.+";
      example = "my_strategies.ema:EMACrossConfig";
      description = "Import path of the ${kind}'s config class.";
    };

    config = mkOption {
      inherit (jsonFormat) type;
      default = {};
      example = literalExpression ''
        {
          instrument_id = "BTCUSDT-PERP.BINANCE";
          bar_type = "BTCUSDT-PERP.BINANCE-1-MINUTE-LAST-EXTERNAL";
          trade_size = "0.010";
        }
      '';
      description = "Keyword arguments for the config class (msgspec-decoded, so strings work for ids/decimals).";
    };
  };

  clientModule = kind:
    types.submodule {
      options = {
        path = mkOption {
          type = types.strMatching ".+:.+";
          example = "nautilus_trader.adapters.binance:BinanceDataClientConfig";
          description = "Import path of the ${kind} client's config class.";
        };

        factory = mkOption {
          type = types.strMatching ".+:.+";
          example = "nautilus_trader.adapters.binance:BinanceLiveDataClientFactory";
          description = "Import path of the ${kind} client factory.";
        };

        config = mkOption {
          inherit (jsonFormat) type;
          default = {};
          example = literalExpression ''
            {
              account_type = "USDT_FUTURES";
              testnet = true;
            }
          '';
          description = "Client config kwargs. Leave API keys out — adapters read them from the environment.";
        };
      };
    };

  nodeModule = types.submodule ({name, ...}: {
    options = {
      service = mkOption {
        type = types.bool;
        default = true;
        description = "Run this node as a user service (systemd on Linux, launchd on macOS). If false, only the JSON config is rendered.";
      };

      traderId = mkOption {
        type = types.strMatching "[^-]+-[^-]+";
        default = "${lib.toUpper name}-001";
        defaultText = literalExpression ''"''${lib.toUpper name}-001"'';
        description = "Trader ID, `NAME-TAG`. Also namespaces this node's keys in a shared Redis cache.";
      };

      environment = mkOption {
        type = types.enum ["live" "sandbox"];
        default = "live";
        description = "`sandbox` simulates execution against live market data; `live` routes real orders.";
      };

      logLevel = mkOption {
        type = types.enum ["TRACE" "DEBUG" "INFO" "WARNING" "ERROR" "OFF"];
        default = "INFO";
        description = "Stdout log level (lands in the journal / launchd log).";
      };

      fileLogLevel = mkOption {
        type = types.nullOr (types.enum ["TRACE" "DEBUG" "INFO" "WARNING" "ERROR"]);
        default = "INFO";
        description = "Log level for the node's rotating log file under `$XDG_STATE_HOME/nautilus-trader/<node>/logs`. `null` disables file logging.";
      };

      redis = {
        enable = mkEnableOption "Redis-backed cache + message bus (state survives restarts; needed for `loadState`)";

        host = mkOption {
          type = types.str;
          default = "127.0.0.1";
          description = "Redis host.";
        };

        port = mkOption {
          type = types.port;
          default = 6379;
          description = "Redis port.";
        };
      };

      saveState = mkOption {
        type = types.bool;
        default = false;
        description = "Persist strategy/actor state on stop.";
      };

      loadState = mkOption {
        type = types.bool;
        default = false;
        description = "Restore strategy/actor state on start (requires `redis.enable`).";
      };

      dataClients = mkOption {
        type = types.attrsOf (clientModule "data");
        default = {};
        description = "Data clients keyed by venue/client name (e.g. `BINANCE`).";
      };

      execClients = mkOption {
        type = types.attrsOf (clientModule "execution");
        default = {};
        description = "Execution clients keyed by venue/client name.";
      };

      strategies = mkOption {
        type = types.listOf (types.submodule {options = importableOptions "strategy";});
        default = [];
        description = "Strategies to load into the node.";
      };

      actors = mkOption {
        type = types.listOf (types.submodule {options = importableOptions "actor";});
        default = [];
        description = "Actors (non-trading components: signal generators, recorders, …) to load.";
      };

      environmentFile = mkOption {
        type = types.nullOr types.str;
        default = cfg.environmentFile;
        defaultText = literalExpression "config.programs.nautilus-trader.environmentFile";
        description = "Runtime dotenv with this node's venue credentials. Defaults to the global one.";
      };

      settings = mkOption {
        inherit (jsonFormat) type;
        default = {};
        example = literalExpression ''
          {
            risk_engine.max_order_submit_rate = "50/00:00:01";
            exec_engine.reconciliation_lookback_mins = 1440;
            timeout_connection = 30.0;
            logging.log_component_levels.Portfolio = "WARNING";
          }
        '';
        description = ''
          Freeform `TradingNodeConfig` JSON, deep-merged over everything the
          typed options generate (this wins). Any field upstream supports —
          data/risk/exec engine tuning, message bus streams, portfolio,
          controller, timeouts — is reachable here.
        '';
      };
    };
  });

  renderNode = name: node: let
    importable = kind: i: {
      "${kind}_path" = i.path;
      config_path = i.configPath;
      inherit (i) config;
    };
    client = c: {
      inherit (c) path config;
      factory.path = c.factory;
    };
    database = {
      type = "redis";
      inherit (node.redis) host port;
    };
    nodeLogDir = "${stateDir}/${name}/logs";
    generated =
      {
        trader_id = node.traderId;
        inherit (node) environment;
        logging =
          {
            log_level = node.logLevel;
            log_colors = false;
          }
          // lib.optionalAttrs (node.fileLogLevel != null) {
            log_level_file = node.fileLogLevel;
            log_directory = nodeLogDir;
          };
        data_clients = lib.mapAttrs (_: client) node.dataClients;
        exec_clients = lib.mapAttrs (_: client) node.execClients;
        strategies = map (importable "strategy") node.strategies;
        actors = map (importable "actor") node.actors;
        save_state = node.saveState;
        load_state = node.loadState;
      }
      // lib.optionalAttrs node.redis.enable {
        cache = {inherit database;};
        message_bus = {inherit database;};
      };
  in
    jsonFormat.generate "nautilus-${name}.json" (lib.recursiveUpdate generated node.settings);

  nodeConfigs = lib.mapAttrs renderNode cfg.nodes;
  serviceNodes = lib.filterAttrs (_: n: n.service) cfg.nodes;

  ## launchd has no EnvironmentFile; source it in a tiny shim instead.
  launchScript = name: node:
    pkgs.writeShellScript "nautilus-${name}" ''
      ${lib.optionalString (node.environmentFile != null) ''
        set -a
        . ${lib.escapeShellArg node.environmentFile}
        set +a
      ''}
      exec ${lib.getExe finalPackage} ${nodeConfigs.${name}}
    '';

  serviceEnv =
    {PYTHONUNBUFFERED = "1";}
    // lib.optionalAttrs (cfg.pythonPath != []) {PYTHONPATH = pythonPathString;};
in {
  options.programs.nautilus-trader = {
    enable = mkEnableOption "NautilusTrader (`nautilus-node`, `nautilus-python`) and its live nodes";

    package = lib.mkPackageOption pkgs "nautilus-trader" {nullable = true;};

    extras = mkOption {
      type = types.listOf (types.enum availableExtras);
      default = [];
      example = ["ib"];
      description = ''
        Upstream extras baked into the package (`ib` for Interactive
        Brokers, `betfair`, `polymarket`, `docker`, `visualization`). The
        Rust-native adapters (Binance, Bybit, OKX, Databento, dYdX,
        Hyperliquid, Kraken, BitMEX, Deribit, Tardis, sandbox, …) are always
        included.
      '';
    };

    pythonPath = mkOption {
      type = types.listOf (types.either types.path types.package);
      default = [];
      example = literalExpression "[ ./strategies ]";
      description = ''
        Directories put on `PYTHONPATH` for every node, holding your
        strategy/actor modules. A path literal is copied into the store, so
        each generation pins the exact strategy code it runs.
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/agenix/nautilus.env";
      description = ''
        Default runtime dotenv for all nodes (venue API keys/secrets —
        `BINANCE_API_KEY`, `BYBIT_API_SECRET`, `DATABENTO_API_KEY`, …).
        Keep it out of the Nix store (agenix/ragenix/sops-nix).
      '';
    };

    nodes = mkOption {
      type = types.attrsOf nodeModule;
      default = {};
      example = literalExpression ''
        {
          binance-testnet = {
            environment = "live";
            dataClients.BINANCE = {
              path = "nautilus_trader.adapters.binance:BinanceDataClientConfig";
              factory = "nautilus_trader.adapters.binance:BinanceLiveDataClientFactory";
              config = { account_type = "USDT_FUTURES"; testnet = true; };
            };
            execClients.BINANCE = {
              path = "nautilus_trader.adapters.binance:BinanceExecClientConfig";
              factory = "nautilus_trader.adapters.binance:BinanceLiveExecClientFactory";
              config = { account_type = "USDT_FUTURES"; testnet = true; };
            };
            strategies = [{
              path = "nautilus_trader.examples.strategies.ema_cross:EMACross";
              configPath = "nautilus_trader.examples.strategies.ema_cross:EMACrossConfig";
              config = {
                instrument_id = "ETHUSDT-PERP.BINANCE";
                bar_type = "ETHUSDT-PERP.BINANCE-1-MINUTE-LAST-EXTERNAL";
                trade_size = "0.010";
              };
            }];
          };
        }
      '';
      description = "Live trading nodes, one `TradingNodeConfig` (and service) each.";
    };
  };

  config = mkIf cfg.enable {
    assertions =
      [
        {
          assertion = cfg.package != null || serviceNodes == {};
          message = "programs.nautilus-trader.nodes.*.service requires programs.nautilus-trader.package to be non-null.";
        }
      ]
      ++ lib.mapAttrsToList (name: node: {
        assertion = !node.loadState || node.redis.enable;
        message = "programs.nautilus-trader.nodes.${name}.loadState needs redis.enable — there's nowhere else to load state from.";
      })
      cfg.nodes;

    home = {
      packages = mkIf (finalPackage != null) [finalPackage];

      activation.nautilusTraderDirectories = mkIf (cfg.nodes != {}) (lib.hm.dag.entryAfter ["writeBoundary"] ''
        ${pkgs.coreutils}/bin/mkdir -p ${lib.concatMapStringsSep " " (n: lib.escapeShellArg "${stateDir}/${n}/logs") (lib.attrNames cfg.nodes)}
      '');
    };

    xdg.configFile =
      lib.mapAttrs' (name: file: lib.nameValuePair "nautilus-trader/nodes/${name}.json" {source = file;})
      nodeConfigs;

    systemd.user.services = mkIf pkgs.stdenv.isLinux (lib.mapAttrs' (name: node:
      lib.nameValuePair "nautilus-${name}" {
        Unit = {
          Description = "NautilusTrader node ${name} (${node.traderId}, ${node.environment})";
          After = ["network-online.target"];
          Wants = ["network-online.target"];
          X-Restart-Triggers = [nodeConfigs.${name}];
        };
        Service = {
          ExecStart = "${lib.getExe finalPackage} ${nodeConfigs.${name}}";
          Environment = lib.mapAttrsToList (n: v: "${n}=${v}") serviceEnv;
          EnvironmentFile = lib.optional (node.environmentFile != null) node.environmentFile;
          WorkingDirectory = "${stateDir}/${name}";
          Restart = "on-failure";
          RestartSec = 10;
          ## The node handles SIGTERM itself (strategies' on_stop, client
          ## disconnects, dispose) — give it room before SIGKILL.
          TimeoutStopSec = 60;
        };
        Install.WantedBy = ["default.target"];
      })
    serviceNodes);

    launchd.agents = mkIf pkgs.stdenv.isDarwin (lib.mapAttrs' (name: node:
      lib.nameValuePair "nautilus-${name}" {
        enable = true;
        config = {
          Label = "io.nautilustrader.${name}";
          ProgramArguments = ["${launchScript name node}"];
          EnvironmentVariables = serviceEnv;
          WorkingDirectory = "${stateDir}/${name}";
          KeepAlive.SuccessfulExit = false;
          RunAtLoad = true;
          ExitTimeOut = 60;
          StandardOutPath = "${stateDir}/${name}/stdout.log";
          StandardErrorPath = "${stateDir}/${name}/stdout.log";
        };
      })
    serviceNodes);
  };
}
