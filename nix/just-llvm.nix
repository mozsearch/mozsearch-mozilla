{
  build-config,
  llvmPackages,
  llvmPackages_git,
}:
build-config {
  configName = "just-llvm";
  inputsFrom = [llvmPackages_git.llvm];
  extraRuntimeInputs = [llvmPackages.bintools]; # for lld
}
