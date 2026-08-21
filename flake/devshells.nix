{inputs, ...}: {
  imports = [inputs.devshell.flakeModule];

  perSystem = {
    pkgs,
    config,
    ...
  }: {
    devshells.default = {
      devshell = rec {
        name = "quant-nixCfg";
        motd = "{202}Welcome to {91}${name} {202}devshell!{reset} \n $(menu)";
        startup = {
          git-hooks.text = ''
            ${config.pre-commit.installationScript}
          '';
        };
        packages = pkgs.lib.attrsets.attrValues {
          inherit
            (pkgs)
            nixd
            alejandra
            uv
            ;
        };
      };
    };
  };
}
