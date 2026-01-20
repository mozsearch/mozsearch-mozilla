{
  build-config,
  scip-python,
  python3Packages,
  mozsearch-tools,
  mozsearch-clang-plugin,
  mozsearch-tests,
}:
build-config {
  configName = "just-mozsearch";
  inputsFrom = [mozsearch-tools mozsearch-clang-plugin mozsearch-tests];
  extraRuntimeInputs = [
    scip-python
    python3Packages.pip
  ];
}
