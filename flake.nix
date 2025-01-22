{
  inputs = {
    flake-utils.url = github:numtide/flake-utils;
    mozsearch.url = "git+https://github.com/nicolas-guichard/mozsearch?ref=nixified&submodules=1";
  };

  nixConfig = {
    extra-substituters = ["https://nix-community.cachix.org"];
    extra-trusted-public-keys = ["nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="];
  };

  outputs = {
    self,
    flake-utils,
    mozsearch,
  }: (
    flake-utils.lib.eachDefaultSystem (
      system: let
        nixpkgs = mozsearch.inputs.nixpkgs;
        fenix = mozsearch.inputs.fenix;

        pkgs = nixpkgs.legacyPackages.${system}.extend fenix.overlays.default;

        mozsearchPackages = mozsearch.packages.${system};

        rustToolchain = pkgs.fenix.combine (with pkgs.fenix; [
          stable.toolchain
          targets.wasm32-unknown-unknown.stable.rust-std
        ]);

        build-config = pkgs.callPackage ./nix/build-config.nix {
          inherit self;
          inherit (mozsearchPackages) build-index mozsearch-tools mozsearch-clang-plugin;
        };
      in {
        packages = {
          index-just-mc = pkgs.callPackage ./nix/just-mc.nix {
            inherit build-config;
            inherit (mozsearchPackages) scip-java scip-python;
          };
          index-just-mozsearch = pkgs.callPackage ./nix/just-mozsearch.nix {
            inherit build-config;
            inherit (mozsearchPackages) mozsearch-tools mozsearch-clang-plugin scip-python;
            mozsearch-tests = mozsearchPackages.tests;
          };
          index-just-graphviz = pkgs.callPackage ./nix/just-graphviz.nix {
            inherit build-config;
          };
          index-just-wubkat = pkgs.callPackage ./nix/just-wubkat.nix {
            inherit build-config;
          };
          index-just-llvm = pkgs.callPackage ./nix/just-llvm.nix {
            inherit build-config;
          };
          index-just-glean = pkgs.callPackage ./nix/just-glean.nix {
            inherit rustToolchain;
            inherit build-config;
          };

          index-config1 = pkgs.callPackage ./nix/config1.nix {
            inherit build-config;
            inherit (mozsearchPackages) scip-java scip-python;
          };
          index-config2 = pkgs.callPackage ./nix/config2.nix {
            inherit build-config;
          };
          index-config3 = pkgs.callPackage ./nix/config3.nix {
            inherit build-config;
          };
          index-config4 = pkgs.callPackage ./nix/config4.nix {
            inherit build-config;
          };
          index-config5 = pkgs.callPackage ./nix/config5.nix {
            inherit build-config;
          };
        };

        checks = self.packages.${system};

        formatter = pkgs.alejandra;
      }
    )
  );
}
