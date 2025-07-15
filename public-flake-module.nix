{ self, ... }:
{
  flake.flakeModule = 
    {
      lib,
      flake-parts-lib,
      inputs,
      ...
    }: let
      inherit (flake-parts-lib) mkPerSystemOption;
      inherit (lib) types;
    in {
      _file = ./public-flake-module.nix;

      options.perSystem = mkPerSystemOption (
        perSystem@{
          config,
          options,
          pkgs,
          system,
          ...
        }: let
          cfg = config.crate2nix;

          crate2nix = self.packages.${pkgs.system}.default;

          mkCargoNix =
            args@{
              pkgs ? perSystem.pkgs
            , rust ? pkgs.rustc
            , cargo ? pkgs.cargo
            , target ? null
            , ...
            }:
            import cfg.cargoNix {
              pkgs =
                if target == null then args.pkgs
                else import pkgs.path {
                  inherit (pkgs) system config overlays;
                  crossSystem =
                    if lib.isString target
                    then { config = target; }
                    else target;
                };

              buildRustCrateForPkgs = crate: pkgs.buildRustCrate.override {
                inherit cargo;
                rustc = rust;
              };
              defaultCrateOverrides = pkgs.defaultCrateOverrides // cfg.crateOverrides;
            };

          cargoNix = mkCargoNix {
            inherit pkgs;
            inherit (cfg.toolchain) rust cargo;
          };

          getMemberBuild = name: member:
            let
              crateOverrides =
                if cfg.crateOverrides ? ${name}
                then cfg.crateOverrides.${name} {}
                else {};
              overrideAttrNames = builtins.attrNames crateOverrides;
              isInOverride = n: lib.elem n overrideAttrNames;
              globalBuildAttrs = [ "pkgs" "rust" "cargo" "target" ];
            in
            if lib.any isInOverride globalBuildAttrs
            then
              (mkCargoNix crateOverrides).workspaceMembers.${name}.build
            else member.build;
        in {
          options.crate2nix = {
            cargoNix = lib.mkOption {
              type = types.nullOr types.path;
              default = null;
              description = ''
                Path to Cargo.nix.
              '';
            };
            toolchain = {
              rust = lib.mkOption {
                type = types.package;
                default = pkgs.rustc;
                description = ''
                  Rust compiler to build with.
                '';
              };
              cargo = lib.mkOption {
                type = types.package;
                default = pkgs.cargo;
                description = ''
                  Cargo command to make available to build processes.
                '';
              };
            };
            crateOverrides = lib.mkOption {
              type = types.attrsOf (types.anything);
              default = {};
              description = ''
                Crate overrides.
              '';
              example = ''
                {
                  openssl = attrs: {
                    nativeBuildInputs = [ pkgs.openssl ];
                  };
                }
              '';
            };
            devshell = lib.mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                Name of devshell to add update-cargo-nix command to.
              '';
            };
          };
          config = lib.mkMerge [
            (lib.mkIf (options ? devshells && cfg.devshell != null) (
              (lib.optionalAttrs (options ? devshells) {
                devshells.${cfg.devshell} = {
                  commands = [
                    {
                      category = "development";
                      name = "update-cargo-nix";
                      help = "Update Cargo.nix";
                      command = "${lib.getExe crate2nix} generate";
                    }
                  ];
                };
              })
            ))
            # Allow for just adding devshell to get access to update-cargo-nix
            (lib.mkIf (cfg.cargoNix != null) {
              packages = lib.mapAttrs getMemberBuild cargoNix.workspaceMembers;
            })
          ];
        }
      );
    };
}
