_: {
  flake.homeManagerModules = {
    default = {
      imports = [
        ./home/openalgo.nix
        ./home/qlib.nix
      ];
    };

    openalgo = import ./home/openalgo.nix;
    qlib = import ./home/qlib.nix;
  };
}
