{
  build-config,
  webkitgtk_6_0,
}:
build-config {
  configName = "just-wubkat";
  inputsFrom = [webkitgtk_6_0];
  extraRuntimeInputs = [];
}
