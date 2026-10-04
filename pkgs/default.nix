{inputs, ...}: {
  perSystem = {
    pkgs,
    lib,
    system,
    ...
  }: {
    packages =
      {
        openalgo = pkgs.callPackage ./openalgo/package.nix {inherit lib pkgs inputs system;};
      }
      ## No x86_64-darwin wheel upstream — see ./nautilus-trader/package.nix.
      // lib.optionalAttrs (system != "x86_64-darwin") {
        nautilus-trader = pkgs.callPackage ./nautilus-trader/package.nix {inherit pkgs inputs;};
      };
  };
}
