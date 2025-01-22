{
  build-config,
  rustToolchain,
}:
build-config {
  configName = "just-glean";
  inputsFrom = [];
  extraRuntimeInputs = [rustToolchain];
}
