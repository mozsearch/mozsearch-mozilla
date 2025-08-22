{
  self,
  mkShell,
  writeShellApplication,
  build-index,
  devShellTools,
  mozsearch-tools,
  mozsearch-clang-plugin,
  git,
  git-cinnabar,
  wget,
  lz4,
  jq,
  jo,
  curl,
  parallel,
  unzip,
  dos2unix,
  ripgrep,
}: {
  configName,
  inputsFrom ? [],
  extraRuntimeInputs ? [],
}: let
  commonScriptsInputs = [
    mozsearch-tools
    git
    git-cinnabar
    wget
    lz4
    jq
    jo
    curl
    parallel
    unzip
    dos2unix
    ripgrep
  ];

  clangStdenv = mozsearch-clang-plugin.passthru.llvmPackages.stdenv;

  shell = mkShell.override {stdenv = clangStdenv;} {
    inherit inputsFrom;
  };

  runtimeEnv = devShellTools.unstructuredDerivationInputEnv {
    drvAttrs =
      shell.drvAttrs
      // {
        nativeBuildInputs = shell.nativeBuildInputs ++ commonScriptsInputs ++ extraRuntimeInputs;

        noDumpEnvVars = true;
        dontAddDisableDepTrack = 1;
        IN_NIX_SHELL = "impure";
        NIX_ENFORCE_PURITY = 0;
        outputs = ["out"];

        src = null;
      };
  };
in
  writeShellApplication {
    name = "index-${configName}";

    inherit runtimeEnv;

    text = ''
      out=$(mktemp -d)/outputs/out
      export out
      . "$stdenv/setup"

      export DONT_INSTALL_DEPS=1
      INDEX_DIR=$1
      ${build-index}/bin/build-index ${self} ${configName}.json "$INDEX_DIR"
    '';

    extraShellCheckFlags = ["-x"];
    excludeShellChecks = ["SC1091" "SC2016" "SC2089" "SC2090"];
  }
