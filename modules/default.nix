_: {
  flake.homeManagerModules = {
    default = {
      imports = [./home/openalgo.nix];
    };

    openalgo = import ./home/openalgo.nix;
  };
}
