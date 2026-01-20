{
  build-config,
  scip-java,
  scip-python,
  python3Packages,
}:
build-config {
  configName = "just-mc";
  extraRuntimeInputs = [
    scip-java
    scip-python
    python3Packages.pip
  ];
}
