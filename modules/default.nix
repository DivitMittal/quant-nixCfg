_: {
  flake.homeManagerModules = {
    default = {
      imports = [
        ./home/openalgo.nix
        ./home/ibkr.nix
      ];
    };

    openalgo = import ./home/openalgo.nix;
    ibkr = import ./home/ibkr.nix;
  };
}
