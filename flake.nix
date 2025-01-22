{
  inputs = {
    mozsearch.url = "git+https://github.com/nicolas-guichard/mozsearch?ref=nixified";
    nixpkgs.follows = "mozsearch/nixpkgs";
    fenix.follows = "mozsearch/fenix";
    flake-utils.follows = "mozsearch/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    fenix,
    mozsearch,
  }: (
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            fenix.overlays.default
          ];
        };

        mozsearchPkgs = mozsearch.packages.${system};

        rustToolchain = pkgs.fenix.combine (with pkgs.fenix; [
          stable.toolchain
          targets.wasm32-unknown-unknown.stable.rust-std
        ]);

        build-config = pkgs.callPackage ./nix/build-config.nix {
          inherit self;
          inherit (mozsearchPkgs) build-index mozsearch-tools mozsearch-clang-plugin;
        };
      in {
        packages = {
          index-just-mc = pkgs.callPackage ./nix/just-mc.nix {
            inherit build-config;
            inherit (mozsearchPkgs) scip-java scip-python;
          };
          index-just-mozsearch = pkgs.callPackage ./nix/just-mozsearch.nix {
            inherit build-config;
            inherit (mozsearchPkgs) mozsearch-tools mozsearch-clang-plugin scip-python;
            mozsearch-tests = mozsearchPkgs.tests;
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
            inherit (mozsearchPkgs) scip-java scip-python;
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

          serve-config = pkgs.callPackage ./nix/serve-config.nix {
            inherit self;
            inherit (mozsearchPkgs) serve-index;
          };
        };

        checks = self.packages.${system};

        formatter = pkgs.alejandra;
      }
    )
  );
}
