{inputs, ...}: {
  perSystem = {
    pkgs,
    lib,
    system,
    ...
  }: {
    packages = {
      openalgo = pkgs.callPackage ./openalgo/package.nix {inherit lib pkgs inputs system;};
      qlib = pkgs.callPackage ./qlib/package.nix {inherit pkgs inputs;};
    };
  };
}
