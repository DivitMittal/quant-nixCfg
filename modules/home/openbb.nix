## programs.openbb — OpenBB Platform as code.
##
## Everything OpenBB reads at runtime funnels through one generated file,
## ~/.openbb_platform/openbb.toml — the user-global layer of OpenBB v5's
## layered config cascade (see openbb_core/app/config/loader.py upstream):
##
##   [user.preferences]          SDK output type, data/cache/export dirs, styles
##   [user.defaults.commands]    default provider (and any default kwargs) per command
##   [system]                    debug/logging, HTTP proxy/CA/timeouts, uvicorn kwargs
##   [settings] + top-level      `openbb` CLI REPL display settings
##   [launcher] / [env]          `openbb-api` flags + env injection
##   [mcp]                       `openbb-mcp` flags
##
## The typed options below cover the commonly-tweaked knobs; `settings` is a
## freeform TOML attrset merged on top, so any key upstream supports (incl.
## future ones) is reachable without touching this module.
##
## Secrets (provider API keys) never go in that file — it's world-readable in
## the Nix store. Point `environmentFile` at an agenix/ragenix-managed dotenv
## (`FRED_API_KEY=...`, `OPENBB_API_PASSWORD=...`); it's linked (out of store)
## to ~/.openbb_platform/.env. That's the one dotenv OpenBB reads *before*
## building its credentials model at import time — `OPENBB_ENV_FILE` is
## applied too late for provider keys to register.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkIf mkOption mkEnableOption types literalExpression;
  cfg = config.programs.openbb;

  tomlFormat = pkgs.formats.toml {};

  availableExtensions =
    lib.attrNames
    (lib.importTOML ../../pkgs/openbb/pyproject.toml).project.optional-dependencies;

  finalPackage =
    if cfg.package == null
    then null
    else cfg.package.override {inherit (cfg) extensions;};

  ## "equity.price.historical" = "yfinance" → {provider = ["yfinance"];}
  ## "equity.price.historical" = {provider = "fmp"; adjustment = "splits_only";} → as-is
  defaultCommands =
    lib.mapAttrs (
      _: value:
        if lib.isAttrs value
        then value
        else {provider = lib.toList value;}
    )
    cfg.defaultProviders;

  generatedSettings = lib.foldl' lib.recursiveUpdate {} [
    {
      user.preferences = lib.filterAttrs (_: v: v != null) {
        data_directory = cfg.dataDir;
        cache_directory = "${cfg.cacheDir}";
        export_directory = "${cfg.dataDir}/exports";
        user_styles_directory = "${cfg.dataDir}/styles/user";
        inherit (cfg.preferences) output_type chart_style table_style request_timeout show_warnings metadata;
      };
    }
    (lib.optionalAttrs (defaultCommands != {}) {
      user.defaults.commands = defaultCommands;
    })
    (lib.optionalAttrs (cfg.http != {}) {
      system.python_settings.http = cfg.http;
    })
    (lib.optionalAttrs cfg.api.enable {
      launcher = {inherit (cfg.api) host port;} // cfg.api.settings;
    })
    (lib.optionalAttrs cfg.mcp.enable {
      mcp =
        {inherit (cfg.mcp) host port transport;}
        // lib.optionalAttrs (cfg.mcp.allowedCategories != []) {
          allowed-categories = lib.concatStringsSep "," cfg.mcp.allowedCategories;
        }
        // lib.optionalAttrs (cfg.mcp.defaultCategories != []) {
          default-categories = lib.concatStringsSep "," cfg.mcp.defaultCategories;
        }
        // lib.optionalAttrs cfg.mcp.toolDiscovery {tool-discovery = true;}
        // cfg.mcp.settings;
    })
  ];

  configFile = tomlFormat.generate "openbb.toml" (lib.recursiveUpdate generatedSettings cfg.settings);

  mkSystemdService = {
    description,
    exec,
  }: {
    Unit = {
      Description = description;
      After = ["network-online.target"];
      Wants = ["network-online.target"];
      X-Restart-Triggers = [configFile];
    };
    Service = {
      ExecStart = exec;
      Environment = ["PYTHONUNBUFFERED=1"];
      Restart = "on-failure";
      WorkingDirectory = cfg.dataDir;
    };
    Install.WantedBy = ["default.target"];
  };

  mkLaunchdAgent = {
    label,
    exec,
  }: {
    enable = true;
    config = {
      Label = label;
      ProgramArguments = [exec];
      EnvironmentVariables.PYTHONUNBUFFERED = "1";
      WorkingDirectory = cfg.dataDir;
      KeepAlive.SuccessfulExit = false;
      RunAtLoad = true;
      StandardOutPath = "${config.xdg.stateHome}/openbb/${label}.log";
      StandardErrorPath = "${config.xdg.stateHome}/openbb/${label}.log";
    };
  };

  serviceOptions = {
    name,
    defaultPort,
  }: {
    enable = mkEnableOption "the OpenBB ${name} as a user service (systemd on Linux, launchd on Darwin)";

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address the ${name} binds to.";
    };

    port = mkOption {
      type = types.port;
      default = defaultPort;
      description = "Port the ${name} listens on.";
    };
  };
in {
  options.programs.openbb = {
    enable = mkEnableOption "OpenBB Platform (SDK, `openbb` CLI, `openbb-api`, `openbb-mcp`)";

    package = lib.mkPackageOption pkgs "openbb" {nullable = true;};

    extensions = mkOption {
      type = types.listOf (types.enum availableExtensions);
      default = ["equity" "yfinance"];
      example = ["equity" "yfinance" "technical" "quantitative" "derivatives" "economy"];
      description = ''
        OpenBB extensions (routers / providers) baked into the package on
        top of the ones `openbb` itself bundles. Each name is an
        optional-dependency group in `pkgs/openbb/pyproject.toml`; the
        package's `openbb-build` step runs at Nix build time for exactly
        this set, so the `obb.*` namespace is fixed per generation.
      '';
    };

    dataDir = mkOption {
      type = types.str;
      default = "${config.xdg.dataHome}/openbb";
      defaultText = literalExpression ''"''${config.xdg.dataHome}/openbb"'';
      description = ''
        OpenBB user data root (`preferences.data_directory`): exports, user
        styles, Workspace apps.json. Replaces upstream's `~/OpenBBUserData`.
      '';
    };

    cacheDir = mkOption {
      type = types.str;
      default = "${config.xdg.cacheHome}/openbb";
      defaultText = literalExpression ''"''${config.xdg.cacheHome}/openbb"'';
      description = "HTTP/provider response cache (`preferences.cache_directory`).";
    };

    preferences = {
      output_type = mkOption {
        type = types.nullOr (types.enum ["OBBject" "dataframe" "polars" "numpy" "dict" "llm"]);
        default = null;
        example = "dataframe";
        description = "Default return type of `obb.*` calls in the Python SDK. `null` keeps upstream's default (`OBBject`).";
      };

      chart_style = mkOption {
        type = types.nullOr (types.enum ["dark" "light"]);
        default = null;
        description = "Chart theme.";
      };

      table_style = mkOption {
        type = types.nullOr (types.enum ["dark" "light"]);
        default = null;
        description = "Table theme.";
      };

      request_timeout = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        example = 30;
        description = "Provider request timeout in seconds.";
      };

      show_warnings = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Surface OpenBB warnings (e.g. provider fallbacks).";
      };

      metadata = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Attach call metadata (args, timing) to every OBBject.";
      };
    };

    defaultProviders = mkOption {
      type = types.attrsOf (types.either (types.either types.str (types.listOf types.str)) tomlFormat.type);
      default = {};
      example = literalExpression ''
        {
          "equity.price.historical" = "yfinance";
          "equity.fundamental.income" = ["sec" "yfinance"];   # fallback order
          "economy.cpi" = { provider = "oecd"; frequency = "monthly"; };
        }
      '';
      description = ''
        Per-command defaults (`[user.defaults.commands]`). A string or list
        sets the provider (a list is a fallback order); an attrset sets
        any default keyword arguments for that command. Applies to the
        Python SDK; `openbb-api` still requires `provider` per request
        (as of 5.0.0).
      '';
    };

    http = mkOption {
      inherit (tomlFormat) type;
      default = {};
      example = literalExpression ''
        {
          proxy = "http://127.0.0.1:3128";
          cafile = "/etc/ssl/certs/ca-certificates.crt";
          timeout = 30;
        }
      '';
      description = ''
        `system.python_settings.http` — applied to every requests/aiohttp
        session OpenBB providers open (proxy, CA bundle, client certs,
        headers, cookies, timeout).
      '';
    };

    environmentFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/agenix/openbb.env";
      description = ''
        Runtime dotenv with provider credentials and other secrets, e.g.
        `FRED_API_KEY=…`, `BLS_API_KEY=…`, `OPENBB_API_AUTH=true`,
        `OPENBB_API_USERNAME=…`, `OPENBB_API_PASSWORD=…`. Any `*_API_KEY`
        variable is picked up as the matching provider credential. Linked
        (out of store) to `~/.openbb_platform/.env`, which the SDK, CLI and
        both services read; keep it out of the Nix store
        (agenix/ragenix/sops-nix).
      '';
    };

    settings = mkOption {
      inherit (tomlFormat) type;
      default = {};
      example = literalExpression ''
        {
          debug-mode = false;
          output-mode = "rich";            # `openbb` CLI
          timezone = "Asia/Kolkata";
          settings.allowed-number-of-rows = 50;
          system.logging_suppress = false;
          system.api_settings.cors.allow_origins = ["https://pro.openbb.co"];
          user.preferences.output_type = "polars";
        }
      '';
      description = ''
        Freeform contents of `~/.openbb_platform/openbb.toml`, deep-merged
        over everything the typed options generate (this wins). See
        `openbb --print-config-template`, `openbb-api --help` and
        `openbb-mcp --help` for the full schema.
      '';
    };

    api =
      serviceOptions {
        name = "Platform API (`openbb-api`, FastAPI — also the OpenBB Workspace backend)";
        defaultPort = 6900;
      }
      // {
        settings = mkOption {
          inherit (tomlFormat) type;
          default = {};
          example = literalExpression ''
            {
              exclude = ["/api/v1/news/*"];
              agents-json = "/path/to/agents.json";
            }
          '';
          description = "Extra `[launcher]` keys (any `openbb-api` flag, hyphenated).";
        };
      };

    mcp =
      serviceOptions {
        name = "MCP server (`openbb-mcp`)";
        defaultPort = 8001;
      }
      // {
        transport = mkOption {
          type = types.enum ["streamable-http" "sse" "stdio"];
          default = "streamable-http";
          description = "MCP transport. `stdio` is for client-spawned use, not the service.";
        };

        allowedCategories = mkOption {
          type = types.listOf types.str;
          default = [];
          example = ["equity" "economy" "news"];
          description = "Tool categories (top-level `obb` namespaces) the server may expose. Empty means all.";
        };

        defaultCategories = mkOption {
          type = types.listOf types.str;
          default = [];
          example = ["equity"];
          description = "Categories enabled at session start. Empty keeps upstream's default (`all`).";
        };

        toolDiscovery = mkOption {
          type = types.bool;
          default = false;
          description = "Hide tools behind search/discovery meta-tools to keep the client's tool list small.";
        };

        settings = mkOption {
          inherit (tomlFormat) type;
          default = {};
          example = literalExpression ''
            { system-prompt = "/path/to/prompt.txt"; }
          '';
          description = "Extra `[mcp]` keys (any `openbb-mcp` flag, hyphenated).";
        };
      };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.package != null || !(cfg.api.enable || cfg.mcp.enable);
        message = "programs.openbb.{api,mcp}.enable require programs.openbb.package to be non-null.";
      }
      {
        assertion = !(cfg.mcp.enable && cfg.mcp.transport == "stdio");
        message = "programs.openbb.mcp: the `stdio` transport can't run as a background service — let the MCP client spawn `openbb-mcp --transport stdio` instead.";
      }
    ];

    home = {
      packages = mkIf (finalPackage != null) [finalPackage];

      file = {
        ".openbb_platform/openbb.toml".source = configFile;
        ".openbb_platform/.env" = mkIf (cfg.environmentFile != null) {
          source = config.lib.file.mkOutOfStoreSymlink cfg.environmentFile;
        };
      };

      activation.openbbDirectories = lib.hm.dag.entryAfter ["writeBoundary"] ''
        ${pkgs.coreutils}/bin/mkdir -p \
          ${lib.escapeShellArg cfg.dataDir}/exports \
          ${lib.escapeShellArg cfg.dataDir}/styles/user \
          ${lib.escapeShellArg cfg.cacheDir} \
          ${lib.escapeShellArg "${config.xdg.stateHome}/openbb"}
      '';
    };

    systemd.user.services = mkIf pkgs.stdenv.isLinux {
      openbb-api = mkIf cfg.api.enable (mkSystemdService {
        description = "OpenBB Platform API";
        exec = "${finalPackage}/bin/openbb-api";
      });
      openbb-mcp = mkIf cfg.mcp.enable (mkSystemdService {
        description = "OpenBB MCP server";
        exec = "${finalPackage}/bin/openbb-mcp";
      });
    };

    launchd.agents = mkIf pkgs.stdenv.isDarwin {
      openbb-api = mkIf cfg.api.enable (mkLaunchdAgent {
        label = "org.openbb.api";
        exec = "${finalPackage}/bin/openbb-api";
      });
      openbb-mcp = mkIf cfg.mcp.enable (mkLaunchdAgent {
        label = "org.openbb.mcp";
        exec = "${finalPackage}/bin/openbb-mcp";
      });
    };
  };
}
