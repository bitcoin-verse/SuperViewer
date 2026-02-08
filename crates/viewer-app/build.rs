fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default() == "windows" {
        let mut res = winres::WindowsResource::new();
        res.set_icon("../../assets/superviewer.ico");
        res.set("ProductName", "SuperViewer");
        res.set("FileDescription", "SuperViewer Image Viewer");
        res.set("LegalCopyright", "Copyright (c) 2025");
        if let Err(e) = res.compile() {
            eprintln!("cargo:warning=Failed to compile Windows resources: {e}");
        }
    }
}
