{inputs, ...}: {
  imports = [inputs.treefmt-nix.flakeModule];

  perSystem.treefmt = {
    projectRootFile = "flake.nix";
    settings.global = {
      excludes = [
        ".github/*"
      ];
    };

    flakeCheck = false;

    programs = {
      alejandra.enable = true;
      deadnix.enable = true;
      statix.enable = true;
    };
  };
}
