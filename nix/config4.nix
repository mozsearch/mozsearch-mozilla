{
  build-config,
  llvmPackages,
  llvmPackages_git,
}:
build-config {
  configName = "config4";
  inputsFrom = [llvmPackages_git.llvm];
  extraRuntimeInputs = [llvmPackages.bintools]; # for lld
}
