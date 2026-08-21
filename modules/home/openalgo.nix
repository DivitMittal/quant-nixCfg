{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkIf mkOption types;
  cfg = config.programs.openalgo;

  environmentValueType = types.oneOf [types.str types.int types.bool];

  formatEnvironmentValue = value:
    if lib.isBool value
    then lib.boolToString value
    else toString value;

  ## OpenAlgo's DATABASE_URL family (db/openalgo.db, db/latency.db, ...) is
  ## relative to the process CWD, so WorkingDirectory doubles as the app's
  ## data root — see .sample.env upstream.
  environment =
    {
      FLASK_HOST_IP = "127.0.0.1";
      FLASK_PORT = 5000;
      WEBSOCKET_HOST = "127.0.0.1";
      WEBSOCKET_PORT = 8765;
    }
    // cfg.environment;
in {
  options.programs.openalgo = {
    enable = lib.mkEnableOption "OpenAlgo self-hosted algo trading platform";

    package = lib.mkPackageOption pkgs "openalgo" {nullable = true;};

    dataDir = mkOption {
      type = types.str;
      default = "${config.xdg.stateHome}/openalgo";
      defaultText = lib.literalExpression ''"\${config.xdg.stateHome}/openalgo"'';
      description = ''
        Working directory for OpenAlgo. Doubles as its data root: the
        `db/` subdirectory holds the sqlite databases named by
        `DATABASE_URL`/`LATENCY_DATABASE_URL`/`LOGS_DATABASE_URL`/etc
        (relative paths, resolved against this directory). Keep persistent.
      '';
    };

    environment = mkOption {
      type = types.attrsOf environmentValueType;
      default = {};
      example = lib.literalExpression ''
        {
          DATABASE_URL = "sqlite:///db/openalgo.db";
          VALID_BROKERS = "zerodha";
          REDIRECT_URL = "http://127.0.0.1:5000/zerodha/callback";
        }
      '';
      description = ''
        Non-secret environment variables for OpenAlgo (see upstream
        `.sample.env` for the full list). Do not place broker credentials,
        `APP_KEY`, `API_KEY_PEPPER`, or `FERNET_SALT` here — they end up
        world-readable in the Nix store via the generated systemd unit.
        Use {option}`programs.openalgo.environmentFiles` instead.
      '';
    };

    environmentFiles = mkOption {
      type = types.listOf types.str;
      default = [];
      example = lib.literalExpression ''
        ["%h/.config/openalgo/secrets.env"]
      '';
      description = ''
        Runtime environment files for the OpenAlgo systemd user service —
        `BROKER_API_KEY`, `BROKER_API_SECRET`, `APP_KEY`, `API_KEY_PEPPER`,
        `FERNET_SALT`, and any XTS market-data credentials belong here.
        Populate via agenix/ragenix, not a Nix store path.
      '';
    };

    service = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to run OpenAlgo as a systemd user service.

          Linux Home Manager hosts with systemd user services only. Darwin
          users can still enable the package and run OpenAlgo manually with
          the declarative environment documented by this module.
        '';
      };

      wantedBy = mkOption {
        type = types.listOf types.str;
        default = ["default.target"];
        description = "Systemd user targets that should start the OpenAlgo service.";
      };

      extraServiceConfig = mkOption {
        type = types.attrsOf types.anything;
        default = {};
        example = lib.literalExpression ''
          {
            RestartSec = 10;
          }
        '';
        description = "Additional systemd service settings for OpenAlgo.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.package != null || !cfg.service.enable;
        message = "programs.openalgo.service.enable requires programs.openalgo.package to be non-null.";
      }
      {
        assertion = pkgs.stdenv.isLinux || !cfg.service.enable;
        message = "programs.openalgo.service.enable is only supported on Linux systemd user sessions.";
      }
    ];

    home.packages = mkIf (cfg.package != null) [cfg.package];

    home.activation.openalgoDataDirectory = lib.hm.dag.entryAfter ["writeBoundary"] ''
      ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArg cfg.dataDir}/db
    '';

    systemd.user.services.openalgo = mkIf cfg.service.enable {
      Unit = {
        Description = "OpenAlgo self-hosted algo trading platform";
        After = ["network-online.target"];
        Wants = ["network-online.target"];
      };

      Service =
        {
          ExecStart = lib.getExe cfg.package;
          Environment =
            lib.mapAttrsToList (
              name: value: "${name}=${formatEnvironmentValue value}"
            )
            environment;
          EnvironmentFile = cfg.environmentFiles;
          Restart = "on-failure";
          WorkingDirectory = cfg.dataDir;
        }
        // cfg.service.extraServiceConfig;

      Install.WantedBy = cfg.service.wantedBy;
    };
  };
}
