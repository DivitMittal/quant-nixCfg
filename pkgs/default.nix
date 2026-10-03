{inputs, ...}: {
  perSystem = {
    pkgs,
    lib,
    system,
    ...
  }: {
    packages = {
      openalgo = pkgs.callPackage ./openalgo/package.nix {inherit lib pkgs inputs system;};
      openbb = pkgs.callPackage ./openbb/package.nix {inherit pkgs inputs;};
    };
  };
}
