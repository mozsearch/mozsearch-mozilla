{
  build-config,
  webkitgtk_6_0,
  graphviz,
}:
build-config {
  configName = "config5";
  inputsFrom = [webkitgtk_6_0 graphviz];
}
