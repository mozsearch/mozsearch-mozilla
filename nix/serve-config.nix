{
  self,
  writeShellApplication,
  serve-index,
}:
writeShellApplication {
  name = "serve-config";

  text = ''
    CONFIG_NAME="$1"
    INDEX_DIR="$2"
    SRV_DIR="$3"

    ${serve-index}/bin/serve-index "${self}" "$CONFIG_NAME.json" "$INDEX_DIR" "$SRV_DIR"
  '';
}
