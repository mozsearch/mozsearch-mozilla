{
  build-config,
  scip-java,
  scip-python,
  python3Packages,
}:
build-config {
  configName = "config1";
  extraRuntimeInputs = [
    scip-java
    scip-python
    python3Packages.pip
  ];
}
