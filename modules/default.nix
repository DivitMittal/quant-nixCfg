_: {
  flake.homeManagerModules = {
    default = {
      imports = [
        ./home/openalgo.nix
        ./home/openbb.nix
      ];
    };

    openalgo = import ./home/openalgo.nix;
    openbb = import ./home/openbb.nix;
  };
}
