{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  cfg = config.programs.ibkr;
  ## Cask is consumed by home-manager-brew's `homebrew.casks`, only present
  ## when the consuming config imports that module
  hasHomebrew = options ? homebrew.casks;
in {
  options.programs.ibkr = {
    enable = lib.mkEnableOption "IBKR Desktop, Interactive Brokers' trading app (macOS, via the `ibkr` Homebrew cask)";
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      warnings =
        lib.optional (!pkgs.stdenv.isDarwin) ''
          programs.ibkr is only supported on macOS (Homebrew cask `ibkr`); nothing is installed on this host.
        ''
        ++ lib.optional (pkgs.stdenv.isDarwin && !hasHomebrew) ''
          programs.ibkr is enabled but the home-manager-brew module (`homebrew.casks`) is not imported; IBKR Desktop will not be installed.
        '';
    }
    ## IBKR Desktop ships as a vendor installer (not a plain .app), so it goes
    ## through brew rather than a brew-nix `pkgs.brewCasks` derivation
    (lib.optionalAttrs hasHomebrew {
      homebrew.casks = lib.optionals pkgs.stdenv.isDarwin ["ibkr"];
    })
  ]);
}
