{
  build-config,
  graphviz,
}:
build-config {
  configName = "just-graphviz";
  inputsFrom = [graphviz];
}
