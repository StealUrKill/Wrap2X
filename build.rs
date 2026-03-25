fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").unwrap() == "windows" {
        // Read name from packer.toml for version info
        let config = std::fs::read_to_string("packer.toml").unwrap_or_default();
        let mut product_name = String::from("Application");
        for line in config.lines() {
            if let Some(val) = line.strip_prefix("name") {
                if let Some(val) = val.trim().strip_prefix('=') {
                    product_name = val.trim().trim_matches('"').to_string();
                    break;
                }
            }
        }

        let mut res = winres::WindowsResource::new();
        res.set_icon("assets/logo.ico");
        res.set("ProductName", &product_name);
        res.set("FileDescription", &product_name);
        res.set("OriginalFilename", &format!("{product_name}.exe"));
        res.set_manifest(r#"
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="requireAdministrator" uiAccess="false" />
      </requestedPrivileges>
    </security>
  </trustInfo>
</assembly>
"#);
        res.compile().unwrap();
    }
}
