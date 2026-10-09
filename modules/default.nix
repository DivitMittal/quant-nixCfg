_: {
  flake.homeManagerModules = {
    default = {
      imports = [
        ./home/openalgo.nix
        ./home/nautilus-trader.nix
      ];
    };

    openalgo = import ./home/openalgo.nix;
    nautilus-trader = import ./home/nautilus-trader.nix;
  };
}
